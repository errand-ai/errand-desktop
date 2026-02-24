import Foundation
import Containerization
import ContainerizationOCI
import ContainerizationEXT4
@preconcurrency import Network
import SystemPackage

/// Debug log to file since print() doesn't appear in menu bar apps.
private func debugLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let logPath = "/tmp/errand-debug.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

/// Writer that captures container stdout/stderr to the debug log and optionally
/// forwards each line to a callback (e.g. for the Logs window).
private final class DebugWriter: Writer, @unchecked Sendable {
    private let prefix: String
    private let onLine: (@Sendable (String) -> Void)?

    init(prefix: String, onLine: (@Sendable (String) -> Void)? = nil) {
        self.prefix = prefix
        self.onLine = onLine
    }

    func write(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.isEmpty {
                debugLog("[\(prefix)] \(line)")
                onLine?(String(line))
            }
        }
    }

    func close() throws {}
}

/// Manages OCI container lifecycle using Apple's Containerization framework.
/// Handles image pulling, container creation, start/stop, and networking.
actor ContainerEngine {

    // MARK: - Properties

    /// The shared ContainerManager that owns the VM network and kernel.
    private var manager: ContainerManager?

    /// Image store for pulling and caching OCI images.
    private var imageStore: ImageStore?

    /// Tracks running service containers by their container ID.
    private var containers: [String: LinuxContainer] = [:]

    /// Maps service IDs (e.g. "postgres") to container IDs.
    private var serviceContainerMap: [String: String] = [:]

    /// Container IDs whose processes have exited (detected by background `wait()`).
    private var exitedContainers: Set<String> = []

    /// Tracks task-runner containers created via the bridge API.
    private var taskContainers: [String: LinuxContainer] = [:]

    /// Per-container log stream continuations.
    private var logContinuations: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]

    /// Tracks exit status for task-runner containers.
    private var taskContainerExitStatus: [String: (status: String, exitCode: Int?)] = [:]

    /// Storage manager for resolving data directory paths.
    private let storageManager = StorageManager()

    /// Bridge API auth token, set by AppState after BridgeServer init.
    var bridgeToken: String = ""

    /// Bridge API port, matches BridgeServer's listen port.
    var bridgePort: UInt16 = 9876

    /// The vmnet gateway IP — containers use this to reach the host.
    private var hostGatewayIP: String = "127.0.0.1"

    /// Credential encryption key from Keychain, injected into backend/worker containers.
    var credentialEncryptionKey: String = ""

    /// LiteLLM master key from Keychain, used as the LiteLLM API key for all containers.
    var litellmMasterKey: String = ""

    // MARK: - Configuration

    /// Sets the bridge API credentials that will be injected into the worker container.
    func setBridgeCredentials(token: String, port: UInt16) {
        self.bridgeToken = token
        self.bridgePort = port
    }

    /// Sets the credential encryption key (from Keychain) for backend/worker containers.
    func setCredentialEncryptionKey(_ key: String) {
        self.credentialEncryptionKey = key
    }

    /// Sets the LiteLLM master key (from Keychain) injected into litellm, backend, and worker.
    func setLiteLLMMasterKey(_ key: String) {
        self.litellmMasterKey = key
    }

    // MARK: - Initialization

    /// Kata Containers kernel version and URL (arm64 static build).
    private static let kataVersion = "3.17.0"
    private static let kataURL = "https://github.com/kata-containers/kata-containers/releases/download/\(kataVersion)/kata-static-\(kataVersion)-arm64.tar.xz"

    /// Sets up the ContainerManager with a kernel and network.
    private func ensureInitialized() async throws {
        guard manager == nil else { return }

        let store = ImageStore.default
        imageStore = store

        // Clean up orphaned container directories from previous runs
        Self.cleanupOrphanedContainers(imageStore: store)

        // Get or download the Linux kernel binary
        let kernelPath = try await Self.ensureKernelBinary()
        let kernel = Kernel(path: kernelPath, platform: .linuxArm)

        // Pull the vminit image (public, no auth needed)
        let vminitRef = "ghcr.io/apple/containerization/vminit:0.26.0"
        _ = try await store.pull(reference: vminitRef)

        // Retry vmnet creation — the OS may need time to reclaim resources
        // from a previously killed app process
        let network: ContainerManager.VmnetNetwork = try await {
            var lastError: Error?
            for attempt in 1...5 {
                do {
                    return try ContainerManager.VmnetNetwork()
                } catch {
                    lastError = error
                    debugLog("[ContainerEngine] vmnet creation attempt \(attempt)/5 failed: \(error)")
                    if attempt < 5 {
                        try await Task.sleep(for: .seconds(2))
                    }
                }
            }
            throw lastError!
        }()

        hostGatewayIP = network.ipv4Gateway.description
        debugLog("[ContainerEngine] vmnet gateway: \(hostGatewayIP)")

        manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: vminitRef,
            imageStore: store,
            network: network
        )
    }

    /// Removes orphaned task-runner container directories from previous app sessions.
    /// Service containers (errand-*) are left alone — their stale directories are cleaned
    /// up individually in createAndStartContainer() right before re-creation.
    private static func cleanupOrphanedContainers(imageStore: ImageStore) {
        let fm = FileManager.default
        let containersDir = imageStore.path.appendingPathComponent("containers")
        guard let entries = try? fm.contentsOfDirectory(atPath: containersDir.path) else { return }
        let orphans = entries.filter { $0.hasPrefix("task-") }
        if !orphans.isEmpty {
            debugLog("[ContainerEngine] Cleaning up \(orphans.count) orphaned task container(s)")
        }
        for name in orphans {
            try? fm.removeItem(at: containersDir.appendingPathComponent(name))
        }
    }

    /// Downloads the Kata Containers kernel binary if not already cached.
    /// Returns the URL to the vmlinux binary.
    private static func ensureKernelBinary() async throws -> URL {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ErrandDesktop")
            .appendingPathComponent("kernel")
        let vmlinuxPath = cacheDir.appendingPathComponent("vmlinux")

        // Return cached kernel if it exists
        if fm.fileExists(atPath: vmlinuxPath.path) {
            return vmlinuxPath
        }

        debugLog("[ContainerEngine] Downloading Kata Containers kernel \(kataVersion)...")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Download the tar.xz archive to a temp file (291MB, too large for in-memory)
        let archivePath = cacheDir.appendingPathComponent("kata.tar.xz")
        let (tempURL, response) = try await URLSession.shared.download(from: URL(string: kataURL)!)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw ContainerEngineError.kernelDownloadFailed
        }

        // Move downloaded file to our cache directory
        try? fm.removeItem(at: archivePath)
        try fm.moveItem(at: tempURL, to: archivePath)

        // Extract the kernel binary from the archive.
        // vmlinux.container is a symlink, so extract all vmlinux files
        // and resolve the symlink to find the real binary.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archivePath.path, "-C", cacheDir.path, "--strip-components=5",
                             "--include=./opt/kata/share/kata-containers/vmlinux*",
                             "--exclude=*dragonball*", "--exclude=*nvidia*"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ContainerEngineError.kernelDownloadFailed
        }

        // Find the actual kernel binary (not symlinks)
        let contents = try fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for file in contents where file.lastPathComponent.hasPrefix("vmlinux") && file.lastPathComponent != "vmlinux" {
            let isSymlink = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if !isSymlink && file.lastPathComponent != "vmlinux.container" {
                try? fm.removeItem(at: vmlinuxPath)
                try fm.moveItem(at: file, to: vmlinuxPath)
                break
            }
        }

        // Clean up symlinks and other extracted files
        for file in (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? [] {
            if file.lastPathComponent.hasPrefix("vmlinux") && file.lastPathComponent != "vmlinux" {
                try? fm.removeItem(at: file)
            }
        }

        // Clean up archive
        try? fm.removeItem(at: archivePath)

        guard fm.fileExists(atPath: vmlinuxPath.path) else {
            throw ContainerEngineError.kernelDownloadFailed
        }

        debugLog("[ContainerEngine] Kernel binary ready at \(vmlinuxPath.path)")
        return vmlinuxPath
    }

    // MARK: - Image Pulling (Task 3.1)

    /// Pulls an OCI image by fully-qualified reference. Caches locally via ImageStore.
    func pullImage(name: String) async throws {
        try await ensureInitialized()
        guard let imageStore else { throw ContainerEngineError.notInitialized }
        _ = try await imageStore.pull(reference: name)
    }

    /// Expands short-form image references to fully-qualified form.
    /// e.g. "nginx:latest" → "docker.io/library/nginx:latest",
    ///      "myorg/myimage:v1" → "docker.io/myorg/myimage:v1"
    /// Already-qualified references are returned unchanged.
    static func qualifyImageReference(_ ref: String) -> String {
        // Already has a domain (contains a dot or localhost)
        let slashParts = ref.split(separator: "/", maxSplits: 1)
        if slashParts.count >= 2 {
            let firstPart = String(slashParts[0])
            if firstPart.contains(".") || firstPart.contains(":") {
                return ref // e.g. ghcr.io/org/image:tag or localhost:5000/image
            }
            // org/image form → docker.io/org/image
            return "docker.io/\(ref)"
        }
        // Simple name like "nginx:latest" → docker.io/library/nginx:latest
        return "docker.io/library/\(ref)"
    }

    /// Returns the fully-qualified OCI image reference for a service ID.
    func imageReference(for serviceId: String, config: AppConfig) -> String? {
        let specs = imageSpecs(for: [ServiceInfo(id: serviceId, displayName: "")], config: config)
        return specs[serviceId]
    }

    // MARK: - Container Creation & Start (Tasks 3.2, 3.3)

    /// Callback for forwarding container log lines to the UI.
    typealias LogCallback = @Sendable (String) -> Void

    /// Creates and starts a container, returning its ID and IP address.
    /// Returns the rootfs size in bytes for a given service.
    /// Larger images (LiteLLM, Hindsight) need more space for extraction plus runtime writes.
    private func rootfsSize(for serviceId: String) -> UInt64 {
        switch serviceId {
        case "litellm":    return 8 * 1024 * 1024 * 1024  // 8 GiB — large Python image
        case "hindsight":  return 8 * 1024 * 1024 * 1024  // 8 GiB — ~3 GB extracted
        case "backend":    return 4 * 1024 * 1024 * 1024  // 4 GiB
        case "worker":     return 4 * 1024 * 1024 * 1024  // 4 GiB
        default:           return 2 * 1024 * 1024 * 1024  // 2 GiB — small alpine images
        }
    }

    /// Estimated actual content size for progress calculation.
    /// rootfsSize is the sparse file ceiling (much larger than actual content).
    /// These values are measured from real extractions.
    private func estimatedContentSize(for serviceId: String) -> UInt64 {
        switch serviceId {
        case "litellm":    return 1_500_000_000  // ~1.45 GB measured
        case "hindsight":  return 3_000_000_000  // ~3 GB estimated
        case "backend":    return   550_000_000  // ~527 MB measured (errand image)
        case "worker":     return   550_000_000  // ~527 MB measured (errand image)
        case "migrate":    return   550_000_000  // ~527 MB measured (errand image)
        case "postgres":   return   450_000_000  // ~430 MB estimated (pgvector/pgvector:pg16, Debian-based)
        case "valkey":     return    15_000_000  // ~9 MB measured (alpine)
        default:           return   500_000_000  // conservative default
        }
    }

    /// Callback for reporting rootfs extraction progress (0.0–1.0).
    typealias ProgressCallback = @Sendable (Double) -> Void

    func createAndStartContainer(
        image: String,
        env: [String: String],
        mounts: [Containerization.Mount],
        ports: [Int: Int],
        command: [String]? = nil,
        rootfsSizeInBytes: UInt64 = 4 * 1024 * 1024 * 1024,
        estimatedContentBytes: UInt64 = 500_000_000,
        serviceId: String? = nil,
        onLog: LogCallback? = nil,
        onPreparingProgress: ProgressCallback? = nil
    ) async throws -> (containerId: String, ip: String) {
        try await ensureInitialized()
        guard var manager else { throw ContainerEngineError.notInitialized }
        guard let imageStore else { throw ContainerEngineError.notInitialized }

        // Use stable IDs for service containers so we can clean up deterministically
        let containerId = if let serviceId { "errand-\(serviceId)" } else { "errand-\(UUID().uuidString.prefix(8).lowercased())" }

        let containerDir = imageStore.path
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
        let hasExistingDir = FileManager.default.fileExists(atPath: containerDir.path)
        // Invalidate cached rootfs if the image has changed (e.g. postgres:16-alpine → pgvector:pg16).
        // We store the image reference in a .image-ref file alongside rootfs.ext4.
        let imageRefFile = containerDir.appendingPathComponent(".image-ref")
        if hasExistingDir {
            let cachedRef = try? String(contentsOf: imageRefFile, encoding: .utf8)
            if cachedRef != image {
                debugLog("[ContainerEngine] Cached rootfs image mismatch for \(containerId): cached=\(cachedRef ?? "nil"), requested=\(image) — invalidating cache")
                try? FileManager.default.removeItem(at: containerDir)
            }
        }
        let hasExistingRootfs = FileManager.default.fileExists(atPath: containerDir.path)

        debugLog("[ContainerEngine] Creating container \(containerId) from \(image) with \(mounts.count) mount(s), command=\(command?.description ?? "nil"), rootfs=\(rootfsSizeInBytes / (1024*1024*1024))GiB\(hasExistingRootfs ? " (reusing cached rootfs)" : "")")

        let stdoutWriter = DebugWriter(prefix: "\(containerId) stdout", onLine: onLog)
        let stderrWriter = DebugWriter(prefix: "\(containerId) stderr", onLine: onLog)

        // Poll rootfs disk usage during extraction to report progress.
        // The file is sparse, so allocated blocks / target size gives a rough %.
        let startProgressPoller: () -> Task<Void, Never>? = {
            guard let onPreparingProgress else { return nil }
            let targetBytes = estimatedContentBytes
            let containerDirPath = containerDir.path
            return Task.detached {
                let fm = FileManager.default
                var ext4CachedPath: String?
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))

                    if ext4CachedPath == nil {
                        if let enumerator = fm.enumerator(atPath: containerDirPath) {
                            while let file = enumerator.nextObject() as? String {
                                if file.hasSuffix(".ext4") {
                                    ext4CachedPath = containerDirPath + "/" + file
                                    break
                                }
                            }
                        }
                    }

                    guard let foundPath = ext4CachedPath else { continue }

                    let rootfsURL = URL(fileURLWithPath: foundPath)
                    guard let values = try? rootfsURL.resourceValues(forKeys: [.fileAllocatedSizeKey]),
                          let allocatedSize = values.fileAllocatedSize else { continue }

                    let progress = min(Double(allocatedSize) / Double(targetBytes), 0.99)
                    onPreparingProgress(progress)
                }
            }
        }
        var progressPoller = startProgressPoller()

        var container: LinuxContainer
        let rootfsFile = containerDir.appendingPathComponent("rootfs.ext4")
        let hasExistingRootfsFile = hasExistingRootfs && FileManager.default.fileExists(atPath: rootfsFile.path)

        if hasExistingRootfsFile {
            // Reuse the cached rootfs from a previous clean shutdown.
            // Wrap the entire lifecycle (create config → boot VM → start) so that
            // any failure (corrupt ext4, mount EINVAL, etc.) falls back to a full re-extract.
            progressPoller?.cancel()
            onPreparingProgress?(1.0)
            do {
                let rootfsMount = Mount.block(
                    format: "ext4",
                    source: rootfsFile.path,
                    destination: "/",
                    options: []
                )
                let ociImage = try await imageStore.get(reference: image, pull: false)
                container = try await manager.create(
                    containerId,
                    image: ociImage,
                    rootfs: rootfsMount
                ) { config in
                    config.cpus = 2
                    config.memoryInBytes = 1024 * 1024 * 1024
                    config.process.stdout = stdoutWriter
                    config.process.stderr = stderrWriter
                    if let command { config.process.arguments = command }
                    for (key, value) in env { config.process.environmentVariables.append("\(key)=\(value)") }
                    for mount in mounts { config.mounts.append(mount) }
                }
                try await container.create()
                try await container.start()
                debugLog("[ContainerEngine] Reused cached rootfs for \(containerId)")
            } catch {
                debugLog("[ContainerEngine] Cached rootfs unusable for \(containerId), re-extracting: \(error)")
                try? manager.releaseNetwork(containerId)
                try? FileManager.default.removeItem(at: containerDir)
                // Restart progress reporting for the fresh extraction
                onPreparingProgress?(0.0)
                progressPoller = startProgressPoller()
                container = try await manager.create(
                    containerId, reference: image,
                    rootfsSizeInBytes: rootfsSizeInBytes
                ) { config in
                    config.cpus = 2
                    config.memoryInBytes = 1024 * 1024 * 1024
                    config.process.stdout = stdoutWriter
                    config.process.stderr = stderrWriter
                    if let command { config.process.arguments = command }
                    for (key, value) in env { config.process.environmentVariables.append("\(key)=\(value)") }
                    for mount in mounts { config.mounts.append(mount) }
                }
                progressPoller?.cancel()
                onPreparingProgress?(1.0)
                try await container.create()
                try await container.start()
            }
        } else {
            // No cached rootfs — extract fresh from the image
            if hasExistingRootfs {
                try? FileManager.default.removeItem(at: containerDir)
            }
            do {
                container = try await manager.create(
                    containerId, reference: image,
                    rootfsSizeInBytes: rootfsSizeInBytes
                ) { config in
                    config.cpus = 2
                    config.memoryInBytes = 1024 * 1024 * 1024
                    config.process.stdout = stdoutWriter
                    config.process.stderr = stderrWriter
                    if let command { config.process.arguments = command }
                    for (key, value) in env { config.process.environmentVariables.append("\(key)=\(value)") }
                    for mount in mounts { config.mounts.append(mount) }
                }
            } catch {
                progressPoller?.cancel()
                throw error
            }
            progressPoller?.cancel()
            onPreparingProgress?(1.0)
            try await container.create()
            try await container.start()
        }

        // Record which image was used so we can invalidate the cache on image changes.
        try? image.write(to: imageRefFile, atomically: true, encoding: .utf8)

        let ip: String
        if let iface = container.interfaces.first {
            ip = iface.ipv4Address.address.description
            debugLog("[ContainerEngine] Container \(containerId) started, ip=\(ip), interfaces=\(container.interfaces.count)")
        } else {
            ip = "127.0.0.1"
            debugLog("[ContainerEngine] Container \(containerId) started, NO interfaces, falling back to 127.0.0.1")
        }

        // Monitor container exit in background to catch crashes.
        // Marks the container as exited so the health checker can detect it immediately.
        Task {
            do {
                let status = try await container.wait()
                debugLog("[ContainerEngine] Container \(containerId) EXITED with code \(status.exitCode)")
                self.exitedContainers.insert(containerId)
            } catch {
                debugLog("[ContainerEngine] Container \(containerId) wait error: \(error)")
                self.exitedContainers.insert(containerId)
            }
        }

        containers[containerId] = container
        return (containerId, ip)
    }

    /// Stops a container by service ID: SIGTERM, wait 10s, then SIGKILL.
    func stopContainer(serviceId: String, onLog: LogCallback? = nil) async throws {
        guard let containerId = serviceContainerMap[serviceId],
              let container = containers[containerId] else {
            return
        }

        onLog?("Stopping \(serviceId)...")

        do {
            try await container.kill(SIGTERM)
        } catch {
            // Container may have already exited
        }

        // Poll for container exit over 10 seconds (graceful shutdown window).
        // The background exit monitor (started in createAndStartContainer)
        // adds to exitedContainers when container.wait() completes.
        var exited = exitedContainers.contains(containerId)
        if !exited {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if exitedContainers.contains(containerId) {
                    exited = true
                    break
                }
            }
        }

        if !exited {
            onLog?("\(serviceId) did not stop within 10s, forcing...")
            try? await container.kill(SIGKILL)
            // Brief wait for SIGKILL
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(500))
                if exitedContainers.contains(containerId) { break }
            }
        } else {
            onLog?("\(serviceId) exited gracefully")
        }

        // Best-effort VM stop. The process is already dead (SIGTERM or SIGKILL above).
        // Run in a detached task so we don't block if it hangs.
        Task { try? await container.stop() }

        // Release the network IP allocation but keep the container directory
        // for rootfs reuse on next start.
        try? manager?.releaseNetwork(containerId)
        exitedContainers.remove(containerId)
        containers.removeValue(forKey: containerId)
        serviceContainerMap.removeValue(forKey: serviceId)
        onLog?("\(serviceId) cleaned up")
    }

    /// Returns true if the container process for a service has exited unexpectedly.
    func hasExited(serviceId: String) -> Bool {
        guard let containerId = serviceContainerMap[serviceId] else { return false }
        return exitedContainers.contains(containerId)
    }

    /// Runs a command inside a running container.
    func execInContainer(
        containerId: String,
        command: [String]
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let container = containers[containerId] ?? taskContainers[containerId] else {
            throw ContainerEngineError.containerNotFound(containerId)
        }

        let execId = "exec-\(UUID().uuidString.prefix(8).lowercased())"
        let proc = try await container.exec(execId) { config in
            config.arguments = command
            config.workingDirectory = "/"
        }
        try await proc.start()
        let status = try await proc.wait()
        try await proc.delete()

        return (status.exitCode, "", "")
    }

    // MARK: - Dependency-Ordered Startup (Task 3.5)

    /// Callback for reporting status changes during startup.
    typealias StatusCallback = @Sendable (String, ServiceStatus, String?) -> Void

    /// Starts all services in dependency order, waiting for each to become healthy.
    /// Returns the updated services array. Calls `onStatus` when each service's status changes.
    /// Calls `onLog` with (serviceId, line) for each container stdout/stderr line.
    func startAll(services: [ServiceInfo], config: AppConfig, onStatus: StatusCallback? = nil, onLog: (@Sendable (String, String) -> Void)? = nil, onPreparingProgress: (@Sendable (String, Double) -> Void)? = nil) async throws -> [ServiceInfo] {
        var services = services
        try await ensureInitialized()

        let images = imageSpecs(for: services, config: config)

        var skipServices = Set<String>()
        if !config.useLiteLLM { skipServices.insert("litellm") }
        if !config.useHindsight { skipServices.insert("hindsight") }

        // Determine which services to start based on dependencies
        let allServiceIds = serviceDependencies.keys.filter { !skipServices.contains($0) }
        var serviceIPs: [String: String] = [:]
        var completed = Set<String>()     // Services that finished (healthy or ephemeral exited)
        var failed = Set<String>()

        // Mark already-running services as completed (e.g. started during setup wizard)
        for serviceId in allServiceIds {
            guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
            if services[idx].status == .running, serviceContainerMap[serviceId] != nil {
                if let ip = services[idx].containerIP {
                    serviceIPs[serviceId] = ip
                }
                completed.insert(serviceId)
            }
        }

        // Also mark skipped dependencies as completed so dependents aren't blocked
        for serviceId in skipServices {
            completed.insert(serviceId)
        }

        // Process services in dependency order, launching in parallel where possible
        while completed.count + failed.count < allServiceIds.count {
            try Task.checkCancellation()
            // Find services whose dependencies are all satisfied
            let ready = allServiceIds.filter { id in
                !completed.contains(id) && !failed.contains(id) &&
                (serviceDependencies[id] ?? []).allSatisfy { completed.contains($0) }
            }

            guard !ready.isEmpty else {
                // All remaining services are blocked by failures
                break
            }

            // Start all ready services in parallel using a TaskGroup
            try await withThrowingTaskGroup(of: (String, ServiceInfo).self) { taskGroup in
                for serviceId in ready {
                    guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
                    guard let imageName = images[serviceId] else { continue }

                    // Capture values before closure to satisfy Sendable requirements
                    let serviceSnapshot = services[idx]
                    let ipsSnapshot = serviceIPs

                    taskGroup.addTask {
                        return try await self.startSingleService(
                            serviceId: serviceId,
                            service: serviceSnapshot,
                            imageName: imageName,
                            config: config,
                            serviceIPs: ipsSnapshot,
                            onStatus: onStatus,
                            onLog: onLog,
                            onPreparingProgress: onPreparingProgress
                        )
                    }
                }

                for try await (serviceId, updatedService) in taskGroup {
                    guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
                    services[idx] = updatedService
                    if updatedService.status == .running || updatedService.status == .stopped {
                        completed.insert(serviceId)
                        if let ip = updatedService.containerIP {
                            serviceIPs[serviceId] = ip
                        }
                    } else {
                        failed.insert(serviceId)
                    }
                }
            }
        }

        return services
    }

    /// Starts a single service: pull, create, start, and wait for healthy/exit.
    /// Called from startAll's TaskGroup for parallel execution.
    private func startSingleService(
        serviceId: String,
        service: ServiceInfo,
        imageName: String,
        config: AppConfig,
        serviceIPs: [String: String],
        onStatus: StatusCallback?,
        onLog: (@Sendable (String, String) -> Void)?,
        onPreparingProgress: (@Sendable (String, Double) -> Void)?
    ) async throws -> (String, ServiceInfo) {
        var service = service

        try Task.checkCancellation()

        service.status = .pulling
        onStatus?(serviceId, .pulling, nil)

        debugLog("[ContainerEngine] Pulling image for \(serviceId): \(imageName)")
        try await pullImage(name: imageName)
        debugLog("[ContainerEngine] Pull complete for \(serviceId)")

        try Task.checkCancellation()

        service.status = .preparing
        onStatus?(serviceId, .preparing, nil)

        let env = buildEnv(for: serviceId, config: config, serviceIPs: serviceIPs)
        let mounts = try buildMountObjects(for: serviceId)

        let logCb: LogCallback? = onLog.map { handler in
            let sid = serviceId
            return { line in handler(sid, line) }
        }
        let command = commandOverride(for: serviceId)
        let progressCb: ProgressCallback? = onPreparingProgress.map { handler in
            let sid = serviceId
            return { progress in handler(sid, progress) }
        }
        let (containerId, ip) = try await createAndStartContainer(
            image: imageName,
            env: env,
            mounts: mounts,
            ports: [:],
            command: command,
            rootfsSizeInBytes: rootfsSize(for: serviceId),
            estimatedContentBytes: estimatedContentSize(for: serviceId),
            serviceId: serviceId,
            onLog: logCb,
            onPreparingProgress: progressCb
        )

        try Task.checkCancellation()

        service.status = .starting
        onStatus?(serviceId, .starting, nil)
        service.containerId = containerId
        service.containerIP = ip
        serviceContainerMap[serviceId] = containerId

        // Wait for healthy or ephemeral exit
        if service.isEphemeral {
            guard let container = containers[containerId] else {
                service.status = .error
                onStatus?(serviceId, .error, nil)
                throw ContainerEngineError.healthCheckTimeout(serviceId)
            }

            debugLog("[ContainerEngine] Waiting for ephemeral container \(serviceId) to complete...")
            let exitStatus = try await container.wait()
            debugLog("[ContainerEngine] Ephemeral container \(serviceId) exited with code \(exitStatus.exitCode)")

            try? await container.stop()
            try? manager?.delete(containerId)
            containers.removeValue(forKey: containerId)
            serviceContainerMap.removeValue(forKey: serviceId)

            if exitStatus.exitCode == 0 {
                service.status = .stopped
                onStatus?(serviceId, .stopped, nil)
            } else {
                service.status = .error
                onStatus?(serviceId, .error, nil)
                throw ContainerEngineError.migrationFailed(exitCode: Int(exitStatus.exitCode))
            }
        } else {
            let healthy = try await waitForHealthy(service: service, timeoutSeconds: 120)
            if healthy {
                // Create extra databases that other services depend on
                if serviceId == "postgres", let cid = service.containerId {
                    await ensureDatabase("errand", containerId: cid)
                    await ensureDatabase("litellm", containerId: cid)
                    await ensureDatabase("hindsight", containerId: cid)
                    await ensureExtension("vector", database: "hindsight", containerId: cid)
                }
                service.status = .running
                onStatus?(serviceId, .running, ip)
            } else {
                service.status = .error
                onStatus?(serviceId, .error, nil)
                throw ContainerEngineError.healthCheckTimeout(serviceId)
            }
        }

        return (serviceId, service)
    }

    // MARK: - Single Service Start

    /// Starts a single service: pull image, create container, wait for healthy.
    /// Returns the updated ServiceInfo with containerId, containerIP, and status.
    func startService(
        _ service: ServiceInfo,
        config: AppConfig,
        serviceIPs: [String: String],
        onStatus: StatusCallback? = nil,
        onLog: (@Sendable (String, String) -> Void)? = nil,
        onPreparingProgress: (@Sendable (String, Double) -> Void)? = nil
    ) async throws -> ServiceInfo {
        try await ensureInitialized()
        var service = service

        guard let imageName = imageReference(for: service.id, config: config) else {
            throw ContainerEngineError.healthCheckTimeout(service.id)
        }

        service.status = .pulling
        onStatus?(service.id, .pulling, nil)
        try await pullImage(name: imageName)

        service.status = .preparing
        onStatus?(service.id, .preparing, nil)

        let env = buildEnv(for: service.id, config: config, serviceIPs: serviceIPs)
        let mounts = try buildMountObjects(for: service.id)

        let logCb: LogCallback? = onLog.map { handler in
            let sid = service.id
            return { line in handler(sid, line) }
        }

        let progressCb: ProgressCallback? = onPreparingProgress.map { handler in
            let sid = service.id
            return { progress in handler(sid, progress) }
        }
        let (containerId, ip) = try await createAndStartContainer(
            image: imageName,
            env: env,
            mounts: mounts,
            ports: [:],
            command: commandOverride(for: service.id),
            rootfsSizeInBytes: rootfsSize(for: service.id),
            estimatedContentBytes: estimatedContentSize(for: service.id),
            serviceId: service.id,
            onLog: logCb,
            onPreparingProgress: progressCb
        )

        service.containerId = containerId
        service.containerIP = ip

        service.status = .starting
        onStatus?(service.id, .starting, nil)
        serviceContainerMap[service.id] = containerId

        let healthy = try await waitForHealthy(service: service, timeoutSeconds: 120)
        if healthy {
            if service.id == "postgres", let cid = service.containerId {
                await ensureDatabase("litellm", containerId: cid)
                await ensureDatabase("hindsight", containerId: cid)
                await ensureExtension("vector", database: "hindsight", containerId: cid)
            }
            service.status = .running
            onStatus?(service.id, .running, ip)
        } else {
            service.status = .error
            onStatus?(service.id, .error, nil)
            throw ContainerEngineError.healthCheckTimeout(service.id)
        }

        return service
    }

    // MARK: - Reverse-Order Shutdown (Task 3.6)

    /// Stops all services in reverse startup order.
    /// Uses the engine's own serviceContainerMap (not the passed-in containerId)
    /// so containers started mid-startup are properly stopped even if AppState
    /// hasn't received the containerId yet.
    /// Calls `onStatus` for each service as it transitions to stopping/stopped.
    func stopAll(
        services: [ServiceInfo],
        onStatus: StatusCallback? = nil,
        onLog: LogCallback? = nil
    ) async throws -> [ServiceInfo] {
        var services = services
        let order = serviceShutdownOrder()

        for group in order {
            for serviceId in group {
                guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
                guard serviceContainerMap[serviceId] != nil else { continue }

                services[idx].status = .stopping
                onStatus?(serviceId, .stopping, nil)
                try await stopContainer(serviceId: serviceId, onLog: onLog)
                services[idx].status = .stopped
                services[idx].containerId = nil
                services[idx].containerIP = nil
                services[idx].healthCheckFailures = 0
                onStatus?(serviceId, .stopped, nil)
            }
        }

        // Reset any services stuck in intermediate states (e.g. pulling/preparing
        // from a cancelled startup) that had no container to stop.
        for idx in services.indices {
            if services[idx].status != .stopped {
                services[idx].status = .stopped
                services[idx].containerId = nil
                services[idx].containerIP = nil
                onStatus?(services[idx].id, .stopped, nil)
            }
        }

        return services
    }

    // MARK: - Bridge API Methods (called by BridgeServer)

    /// Creates a task-runner container for the bridge API.
    /// Injects `files` at /workspace and mounts an emptyDir at /output for result.json.
    func createTaskContainer(image: String, env: [String: String], files: [String: String]) async throws -> String {
        try await ensureInitialized()
        guard var manager else { throw ContainerEngineError.notInitialized }

        let qualifiedImage = Self.qualifyImageReference(image)
        debugLog("[BridgeServer] createTaskContainer image=\(image) → \(qualifiedImage)")
        try await pullImage(name: qualifiedImage)

        let containerId = "task-\(UUID().uuidString.prefix(8).lowercased())"

        // Write input files to a temporary host directory for mounting at /workspace
        let workspaceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("errand-task-\(containerId)")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        for (filename, content) in files {
            let filePath = workspaceDir.appendingPathComponent(filename)
            try content.write(to: filePath, atomically: true, encoding: .utf8)
        }

        // Create an empty output directory for result.json
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("errand-output-\(containerId)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let container = try await manager.create(
            containerId,
            reference: qualifiedImage,
            rootfsSizeInBytes: 2 * 1024 * 1024 * 1024
        ) { config in
            config.cpus = 1
            config.memoryInBytes = 256 * 1024 * 1024

            for (key, value) in env {
                config.process.environmentVariables.append("\(key)=\(value)")
            }

            // Mount input files at /workspace and output dir at /output
            config.mounts.append(Mount.share(source: workspaceDir.path, destination: "/workspace"))
            config.mounts.append(Mount.share(source: outputDir.path, destination: "/output"))
        }

        try await container.create()
        try await container.start()

        taskContainers[containerId] = container
        taskContainerExitStatus[containerId] = (status: "running", exitCode: nil)

        // Monitor container exit in the background
        Task { [weak self] in
            guard let self else { return }
            do {
                let exitStatus = try await container.wait()
                await self.recordTaskContainerExit(id: containerId, exitCode: Int(exitStatus.exitCode))
            } catch {
                await self.recordTaskContainerExit(id: containerId, exitCode: -1)
            }
        }

        return containerId
    }

    /// Records that a task-runner container has exited and finishes its log stream.
    private func recordTaskContainerExit(id: String, exitCode: Int) {
        taskContainerExitStatus[id] = (status: "exited", exitCode: exitCode)
        logContinuations[id]?.finish()
        logContinuations.removeValue(forKey: id)
    }

    /// Returns a container's status ("running" or "exited") and exit code if exited.
    func containerStatus(_ id: String) async throws -> (status: String, exitCode: Int?) {
        guard let status = taskContainerExitStatus[id] else {
            throw ContainerEngineError.containerNotFound(id)
        }
        return status
    }

    /// Returns an async throwing stream of log lines from a container.
    func containerLogs(_ id: String) async throws -> AsyncThrowingStream<String, Error> {
        guard taskContainers[id] != nil else {
            throw ContainerEngineError.containerNotFound(id)
        }

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        logContinuations[id] = continuation
        return stream
    }

    /// Reads /output/result.json from a task container's output directory.
    /// Since /output is bind-mounted from a host temp directory, we read directly from the host.
    func readContainerOutput(_ id: String) async throws -> String {
        guard taskContainers[id] != nil else {
            throw ContainerEngineError.containerNotFound(id)
        }

        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("errand-output-\(id)")
            .appendingPathComponent("result.json")

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw ContainerEngineError.outputNotFound(id)
        }

        return try String(contentsOf: outputFile, encoding: .utf8)
    }

    /// Stops a container if running, then removes it and cleans up temp directories.
    func stopAndRemoveContainer(_ id: String) async throws {
        guard let container = taskContainers[id] else {
            throw ContainerEngineError.containerNotFound(id)
        }

        try? await container.kill(SIGTERM)
        try? await container.stop()
        try? manager?.delete(id)

        taskContainers.removeValue(forKey: id)
        taskContainerExitStatus.removeValue(forKey: id)
        logContinuations[id]?.finish()
        logContinuations.removeValue(forKey: id)

        // Clean up host-side temp directories
        let fm = FileManager.default
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("errand-task-\(id)"))
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("errand-output-\(id)"))
    }

    /// Builds the environment variables for the backend/worker containers,
    /// routing OPENAI_BASE_URL through LiteLLM when enabled.
    func buildBackendEnv(config: AppConfig, liteLLMManager: LiteLLMManager?) async -> [String: String] {
        var env: [String: String] = [
            "OPENAI_API_KEY": config.openaiAPIKey,
        ]

        if let mgr = liteLLMManager {
            let resolvedURL = await mgr.resolveOpenAIBaseURL(config: config)
            if !resolvedURL.isEmpty {
                env["OPENAI_BASE_URL"] = resolvedURL
            }
        } else if !config.openaiBaseURL.isEmpty {
            env["OPENAI_BASE_URL"] = config.openaiBaseURL
        }

        return env
    }

    // MARK: - Private Helpers

    /// Returns a command override for a service, or nil to use the image default CMD.
    private func commandOverride(for serviceId: String) -> [String]? {
        switch serviceId {
        case "migrate":
            return ["alembic", "upgrade", "head"]
        case "worker":
            return ["python", "worker.py"]
        case "litellm":
            return ["litellm", "--config", "/etc/litellm/config.yaml", "--port", "4000", "--host", "0.0.0.0"]
        default:
            return nil
        }
    }

    /// Maps service IDs to their OCI image references.
    private func imageSpecs(for services: [ServiceInfo], config: AppConfig) -> [String: String] {
        var images: [String: String] = [:]
        for service in services {
            switch service.id {
            case "postgres":
                images["postgres"] = "docker.io/pgvector/pgvector:pg16"
            case "valkey":
                images["valkey"] = "docker.io/valkey/valkey:8-alpine"
            case "backend", "worker", "migrate":
                images[service.id] = "ghcr.io/errand-ai/errand:\(config.contentManagerImageTag)"
            case "litellm":
                images["litellm"] = "ghcr.io/berriai/litellm-database:main-v1.81.3-stable"
            case "hindsight":
                images["hindsight"] = "ghcr.io/vectorize-io/hindsight:0.4.13-slim"
            default:
                break
            }
        }
        return images
    }

    /// Builds environment variables for a service given discovered container IPs.
    private func buildEnv(
        for serviceId: String,
        config: AppConfig,
        serviceIPs: [String: String]
    ) -> [String: String] {
        var env: [String: String] = [:]

        switch serviceId {
        case "postgres":
            env["POSTGRES_USER"] = "postgres"
            env["POSTGRES_PASSWORD"] = "postgres"
            env["POSTGRES_DB"] = "errand"
            env["PGDATA"] = "/var/lib/postgresql/data/pgdata"

        case "valkey":
            env["VALKEY_SAVE"] = "60 1"

        case "migrate":
            if let pgIP = serviceIPs["postgres"] {
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgIP):5432/errand"
            }

        case "backend":
            if let pgIP = serviceIPs["postgres"] {
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgIP):5432/errand"
            }
            if let vkIP = serviceIPs["valkey"] {
                env["VALKEY_URL"] = "redis://\(vkIP):6379"
            }
            env["PORT"] = "\(config.backendPort)"
            if let litellmIP = serviceIPs["litellm"] {
                env["OPENAI_BASE_URL"] = "http://\(litellmIP):\(config.litellmPort)"
                env["OPENAI_API_KEY"] = litellmMasterKey
            } else if !config.openaiBaseURL.isEmpty {
                env["OPENAI_BASE_URL"] = config.openaiBaseURL
                env["OPENAI_API_KEY"] = config.openaiAPIKey
            }
            if !credentialEncryptionKey.isEmpty {
                env["CREDENTIAL_ENCRYPTION_KEY"] = credentialEncryptionKey
            }
            if let hindsightIP = serviceIPs["hindsight"] {
                env["HINDSIGHT_BASE_URL"] = "http://\(hindsightIP):8888"
            }

        case "worker":
            if let pgIP = serviceIPs["postgres"] {
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgIP):5432/errand"
            }
            if let vkIP = serviceIPs["valkey"] {
                env["VALKEY_URL"] = "redis://\(vkIP):6379"
            }
            if let backendIP = serviceIPs["backend"] {
                env["BACKEND_MCP_URL"] = "http://\(backendIP):\(config.backendPort)/mcp"
            }
            if let litellmIP = serviceIPs["litellm"] {
                env["OPENAI_BASE_URL"] = "http://\(litellmIP):\(config.litellmPort)"
                env["OPENAI_API_KEY"] = litellmMasterKey
            } else if !config.openaiBaseURL.isEmpty {
                env["OPENAI_BASE_URL"] = config.openaiBaseURL
                env["OPENAI_API_KEY"] = config.openaiAPIKey
            }
            if !credentialEncryptionKey.isEmpty {
                env["CREDENTIAL_ENCRYPTION_KEY"] = credentialEncryptionKey
            }
            if config.useHindsight, let hindsightIP = serviceIPs["hindsight"] {
                env["HINDSIGHT_URL"] = "http://\(hindsightIP):8888/"
                env["HINDSIGHT_BANK_ID"] = "errand-tasks"
            }
            // Bridge API credentials so the worker can create task-runner containers
            env["CONTAINER_RUNTIME"] = "apple"
            env["CONTAINER_BRIDGE_URL"] = "http://\(hostGatewayIP):\(bridgePort)"
            env["CONTAINER_BRIDGE_TOKEN"] = bridgeToken
            env["TASK_RUNNER_IMAGE"] = "ghcr.io/errand-ai/errand-task-runner:\(config.contentManagerImageTag)"

        case "litellm":
            env["HOST"] = "0.0.0.0"
            env["PORT"] = "4000"
            env["DATABASE_USERNAME"] = "postgres"
            env["DATABASE_PASSWORD"] = "postgres"
            if let pgIP = serviceIPs["postgres"] {
                env["DATABASE_HOST"] = pgIP
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgIP):5432/litellm"
            }
            env["DATABASE_NAME"] = "litellm"
            if !litellmMasterKey.isEmpty {
                env["PROXY_MASTER_KEY"] = litellmMasterKey
                env["LITELLM_MASTER_KEY"] = litellmMasterKey
                env["UI_USERNAME"] = "admin"
                env["UI_PASSWORD"] = litellmMasterKey
            }
            env["LITELLM_MODE"] = "PRODUCTION"
            env["LITELLM_PROXY_CONNECTION_TIMEOUT"] = "600"

        case "hindsight":
            if let pgIP = serviceIPs["postgres"] {
                env["HINDSIGHT_API_DATABASE_URL"] = "postgresql://postgres:postgres@\(pgIP):5432/hindsight"
            }
            env["HINDSIGHT_API_PORT"] = "8888"
            env["HINDSIGHT_API_HOST"] = "0.0.0.0"
            env["HINDSIGHT_CP_HOSTNAME"] = "0.0.0.0"
            // Use 127.0.0.1 instead of localhost — the container VM has no /etc/hosts
            env["HINDSIGHT_CP_DATAPLANE_API_URL"] = "http://127.0.0.1:8888"
            // LLM: "openai" provider — LiteLLM exposes an OpenAI-compatible API
            env["HINDSIGHT_API_LLM_PROVIDER"] = "openai"
            // Embeddings: "litellm" provider — slim image has no local embedding models
            env["HINDSIGHT_API_EMBEDDINGS_PROVIDER"] = "litellm"
            // Reranker: "litellm" provider — slim image has no local reranker models
            env["HINDSIGHT_API_RERANKER_PROVIDER"] = "litellm"
            env["HINDSIGHT_API_RERANKER_LITELLM_MODEL"] = "cohere/rerank-english-v3.0"
            if let litellmIP = serviceIPs["litellm"] {
                let litellmBase = "http://\(litellmIP):\(config.litellmPort)"
                // LLM uses OpenAI-compatible /v1 endpoint
                env["HINDSIGHT_API_LLM_BASE_URL"] = "\(litellmBase)/v1"
                env["HINDSIGHT_API_LLM_API_KEY"] = litellmMasterKey
                // LiteLLM proxy base for embeddings and reranker (no /v1 suffix)
                env["HINDSIGHT_API_LITELLM_API_BASE"] = litellmBase
                env["HINDSIGHT_API_EMBEDDINGS_LITELLM_API_BASE"] = litellmBase
                env["HINDSIGHT_API_EMBEDDINGS_LITELLM_API_KEY"] = litellmMasterKey
            } else if !config.openaiBaseURL.isEmpty {
                env["HINDSIGHT_API_LLM_BASE_URL"] = config.openaiBaseURL
                env["HINDSIGHT_API_LLM_API_KEY"] = config.openaiAPIKey
                // Fall back to OpenAI embeddings when no LiteLLM
                env["HINDSIGHT_API_EMBEDDINGS_PROVIDER"] = "openai"
                env["HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL"] = config.openaiBaseURL
                env["HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY"] = config.openaiAPIKey
            }
            if !config.hindsightLLMModel.isEmpty {
                env["HINDSIGHT_API_LLM_MODEL"] = config.hindsightLLMModel
            }
            if !config.hindsightEmbeddingModel.isEmpty {
                env["HINDSIGHT_API_EMBEDDINGS_LITELLM_MODEL"] = config.hindsightEmbeddingModel
            }

        default:
            break
        }

        return env
    }

    /// Builds Mount objects for a service. Uses ext4 block devices for services that
    /// need full filesystem control (chown, chmod), and virtiofs shares for others.
    private func buildMountObjects(for serviceId: String) throws -> [Containerization.Mount] {
        switch serviceId {
        case "postgres":
            let diskPath = try storageManager.ensureDataDisk(for: "postgres", sizeInMB: 1024)
            debugLog("[ContainerEngine] postgres: using ext4 block device at \(diskPath)")
            return [
                .block(
                    format: "ext4",
                    source: diskPath,
                    destination: "/var/lib/postgresql/data",
                    runtimeOptions: [
                        "vzDiskImageCachingMode=cached",
                        "vzDiskImageSynchronizationMode=fsync",
                    ]
                ),
            ]
        case "valkey":
            let diskPath = try storageManager.ensureDataDisk(for: "valkey", sizeInMB: 256)
            debugLog("[ContainerEngine] valkey: using ext4 block device at \(diskPath)")
            return [
                .block(
                    format: "ext4",
                    source: diskPath,
                    destination: "/data",
                    runtimeOptions: [
                        "vzDiskImageCachingMode=cached",
                        "vzDiskImageSynchronizationMode=fsync",
                    ]
                ),
            ]
        case "litellm":
            let configDir = storageManager.dataPath(for: "litellm")
            return [.share(source: configDir, destination: "/etc/litellm")]
        case "hindsight":
            return [.share(source: storageManager.dataPath(for: "hindsight"), destination: "/data")]
        default:
            return []
        }
    }

    /// Polls health checks until the service is healthy or timeout.
    private func waitForHealthy(service: ServiceInfo, timeoutSeconds: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var attempts = 0

        // On first attempt, log diagnostic info
        debugLog("[ContainerEngine] Waiting for \(service.id) to become healthy (timeout: \(timeoutSeconds)s, ip: \(service.containerIP ?? "nil"), container: \(service.containerId ?? "nil"))")

        while Date() < deadline {
            attempts += 1
            if try await checkHealth(service: service) {
                debugLog("[ContainerEngine] \(service.id) healthy after \(attempts) attempts")
                return true
            }
            if attempts <= 3 || attempts % 10 == 0 {
                debugLog("[ContainerEngine] \(service.id) health check attempt \(attempts) failed")
            }
            // On attempt 5, run a diagnostic exec to check if the process is even running
            if attempts == 5, let containerId = service.containerId {
                await runDiagnostic(service: service.id, containerId: containerId)
            }
            try await Task.sleep(for: .seconds(2))
        }
        debugLog("[ContainerEngine] \(service.id) health check timed out after \(attempts) attempts (\(timeoutSeconds)s)")
        return false
    }

    /// Runs a diagnostic command inside a container and logs the result.
    private func runDiagnostic(service: String, containerId: String) async {
        do {
            let (exitCode, stdout, _) = try await execInContainer(containerId: containerId, command: ["ps", "aux"])
            debugLog("[ContainerEngine] DIAG \(service) ps exit=\(exitCode) stdout=\(stdout)")
        } catch {
            debugLog("[ContainerEngine] DIAG \(service) ps failed: \(error)")
        }
    }

    /// Single health check for a service.
    private func checkHealth(service: ServiceInfo) async throws -> Bool {
        guard let ip = service.containerIP else { return false }

        switch service.id {
        case "postgres":
            // Use pg_isready inside the container — more reliable than TCP from the host
            // because vmnet routing from host to VM may not be established yet
            if let containerId = service.containerId {
                return await execHealthCheck(containerId: containerId, command: ["pg_isready", "-U", "postgres"])
            }
            return await tcpCheck(host: ip, port: 5432)
        case "valkey":
            if let containerId = service.containerId {
                return await execHealthCheck(containerId: containerId, command: ["valkey-cli", "ping"])
            }
            return await tcpCheck(host: ip, port: 6379)
        case "backend":
            return await httpCheck(host: ip, port: 8000, path: "/health")
        case "litellm":
            return await httpCheck(host: ip, port: 4000, path: "/health/liveliness")
        case "hindsight":
            return await httpCheck(host: ip, port: 8888, path: "/health")
        case "worker":
            return true
        default:
            return true
        }
    }

    /// Runs a command inside the container and returns true if exit code is 0.
    /// Creates a database in Postgres if it doesn't already exist.
    /// Uses a single shell command to check and create atomically, avoiding
    /// noisy ERROR logs in the postgres server output.
    private func ensureDatabase(_ name: String, containerId: String) async {
        // psql -tAc outputs just "1" if the DB exists; grep -q exits 0 on match.
        // If the DB doesn't exist, createdb creates it.
        let script = "psql -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname = '\(name)'\" | grep -q 1 || createdb -U postgres \(name)"
        do {
            let (exitCode, _, stderr) = try await execInContainer(
                containerId: containerId,
                command: ["sh", "-c", script]
            )
            if exitCode == 0 {
                debugLog("[ContainerEngine] Database '\(name)' ensured")
            } else {
                debugLog("[ContainerEngine] Failed to ensure database '\(name)': \(stderr)")
            }
        } catch {
            debugLog("[ContainerEngine] Failed to ensure database '\(name)': \(error)")
        }
    }

    private func ensureExtension(_ ext: String, database: String, containerId: String) async {
        let sql = "CREATE EXTENSION IF NOT EXISTS \(ext)"
        do {
            let (exitCode, _, stderr) = try await execInContainer(
                containerId: containerId,
                command: ["psql", "-U", "postgres", "-d", database, "-c", sql]
            )
            if exitCode == 0 {
                debugLog("[ContainerEngine] Extension '\(ext)' ensured in '\(database)'")
            } else {
                debugLog("[ContainerEngine] Failed to create extension '\(ext)' in '\(database)': \(stderr)")
            }
        } catch {
            debugLog("[ContainerEngine] Failed to ensure extension '\(ext)' in '\(database)': \(error)")
        }
    }

    private func execHealthCheck(containerId: String, command: [String]) async -> Bool {
        do {
            let (exitCode, _, _) = try await execInContainer(containerId: containerId, command: command)
            if exitCode != 0 {
                debugLog("[ContainerEngine] exec \(command) in \(containerId) exited \(exitCode)")
            }
            return exitCode == 0
        } catch {
            debugLog("[ContainerEngine] exec \(command) in \(containerId) failed: \(error)")
            return false
        }
    }

    /// TCP connectivity check with 5s timeout.
    private func tcpCheck(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let queue = DispatchQueue(label: "engine-tcp-\(host):\(port)")
            nonisolated(unsafe) var resumed = false

            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    /// HTTP GET health check with 5s timeout.
    private func httpCheck(host: String, port: Int, path: String) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum ContainerEngineError: Error, LocalizedError {
    case notInitialized
    case containerNotFound(String)
    case healthCheckTimeout(String)
    case outputNotFound(String)
    case kernelDownloadFailed
    case migrationFailed(exitCode: Int)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            "ContainerEngine not initialized"
        case .containerNotFound(let id):
            "Container not found: \(id)"
        case .healthCheckTimeout(let service):
            "Health check timed out for service: \(service)"
        case .outputNotFound(let id):
            "Output file not found for container: \(id)"
        case .kernelDownloadFailed:
            "Failed to download Linux kernel binary"
        case .migrationFailed(let exitCode):
            "Database migration failed with exit code \(exitCode)"
        }
    }
}
