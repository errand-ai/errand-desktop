import Foundation
import Containerization
import ContainerizationOCI
import ContainerizationEXT4
@preconcurrency import Network
import SystemPackage

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

/// Apple Containerization framework implementation of the ContainerRuntime protocol.
/// Manages lightweight Linux VMs using Apple's native Containerization APIs.
///
/// Apple's Containerization framework requires macOS 26 (Tahoe) on Apple Silicon.
/// The app itself deploys to macOS 15, so every use of this type must be guarded
/// by `if #available(macOS 26, *)` (see `RuntimeDetector.isAppleContainerizationAvailable`).
@available(macOS 26, *)
actor AppleContainerRuntime: ContainerRuntime {

    /// The shared ContainerManager that owns the VM network and kernel.
    private var manager: ContainerManager?

    /// Image store for pulling and caching OCI images.
    private var imageStore: ImageStore?

    /// Tracks running containers by their container ID.
    private var containers: [String: LinuxContainer] = [:]

    /// Container IDs whose processes have exited (detected by background `wait()`).
    private var exitedContainers: Set<String> = []

    /// Per-container log callbacks, keyed by container ID.
    private var logCallbacks: [String: @Sendable (String) -> Void] = [:]

    /// Per-container progress callbacks, keyed by container ID.
    private var progressCallbacks: [String: @Sendable (Double) -> Void] = [:]

    /// Pending container configs, keyed by container ID (used between create and start).
    private var pendingConfigs: [String: ContainerConfig] = [:]

    /// The vmnet gateway IP — containers use this to reach the host.
    var hostGatewayIP: String = "127.0.0.1"

    /// The storage manager for disk images.
    private let storageManager = StorageManager()

    /// Kata Containers kernel version and URL (arm64 static build).
    private static let kataVersion = "3.17.0"
    private static let kataURL = "https://github.com/kata-containers/kata-containers/releases/download/\(kataVersion)/kata-static-\(kataVersion)-arm64.tar.xz"

    // MARK: - Initialization

    /// Sets up the ContainerManager with a kernel and network.
    func ensureInitialized() async throws {
        guard manager == nil else { return }

        let store = ImageStore.default
        imageStore = store

        cleanupOrphanedContainers(imageStore: store)

        let kernelPath = try await Self.ensureKernelBinary()
        let kernel = Kernel(path: kernelPath, platform: .linuxArm)

        let vminitRef = "ghcr.io/apple/containerization/vminit:0.26.0"
        _ = try await store.pull(reference: vminitRef)

        let network: ContainerManager.VmnetNetwork = try await {
            var lastError: Error?
            for attempt in 1...5 {
                do {
                    return try ContainerManager.VmnetNetwork()
                } catch {
                    lastError = error
                    debugLog("[AppleContainerRuntime] vmnet creation attempt \(attempt)/5 failed: \(error)")
                    if attempt < 5 {
                        try await Task.sleep(for: .seconds(2))
                    }
                }
            }
            throw lastError!
        }()

        hostGatewayIP = network.ipv4Gateway.description
        debugLog("[AppleContainerRuntime] vmnet gateway: \(hostGatewayIP)")

        manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: vminitRef,
            imageStore: store,
            network: network
        )
    }

    // MARK: - Orphaned Container Cleanup

    private func cleanupOrphanedContainers(imageStore: ImageStore) {
        let fm = FileManager.default
        let containersDir = imageStore.path.appendingPathComponent("containers")
        guard let entries = try? fm.contentsOfDirectory(atPath: containersDir.path) else { return }
        let orphans = entries.filter { $0.hasPrefix("task-") }
        if !orphans.isEmpty {
            debugLog("[AppleContainerRuntime] Cleaning up \(orphans.count) orphaned task container(s)")
        }
        for name in orphans {
            try? fm.removeItem(at: containersDir.appendingPathComponent(name))
        }
    }

    // MARK: - Kernel Download

    private static func ensureKernelBinary() async throws -> URL {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ErrandDesktop")
            .appendingPathComponent("kernel")
        let vmlinuxPath = cacheDir.appendingPathComponent("vmlinux")

        if fm.fileExists(atPath: vmlinuxPath.path) { return vmlinuxPath }

        debugLog("[AppleContainerRuntime] Downloading Kata Containers kernel \(kataVersion)...")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let archivePath = cacheDir.appendingPathComponent("kata.tar.xz")
        let (tempURL, response) = try await URLSession.shared.download(from: URL(string: kataURL)!)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw ContainerEngineError.kernelDownloadFailed
        }

        try? fm.removeItem(at: archivePath)
        try fm.moveItem(at: tempURL, to: archivePath)

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

        let contents = try fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for file in contents where file.lastPathComponent.hasPrefix("vmlinux") && file.lastPathComponent != "vmlinux" {
            let isSymlink = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if !isSymlink && file.lastPathComponent != "vmlinux.container" {
                try? fm.removeItem(at: vmlinuxPath)
                try fm.moveItem(at: file, to: vmlinuxPath)
                break
            }
        }

        for file in (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? [] {
            if file.lastPathComponent.hasPrefix("vmlinux") && file.lastPathComponent != "vmlinux" {
                try? fm.removeItem(at: file)
            }
        }

        try? fm.removeItem(at: archivePath)

        guard fm.fileExists(atPath: vmlinuxPath.path) else {
            throw ContainerEngineError.kernelDownloadFailed
        }

        debugLog("[AppleContainerRuntime] Kernel binary ready at \(vmlinuxPath.path)")
        return vmlinuxPath
    }

    // MARK: - ContainerRuntime Protocol

    func pullImage(reference: String, onProgress: (@Sendable (Double) -> Void)?) async throws {
        try await ensureInitialized()
        guard let imageStore else { throw ContainerEngineError.notInitialized }
        _ = try await imageStore.pull(reference: reference)
        onProgress?(1.0)
    }

    func createContainer(id: String, config: ContainerConfig) async throws {
        try await ensureInitialized()
        guard manager != nil else { throw ContainerEngineError.notInitialized }
        guard imageStore != nil else { throw ContainerEngineError.notInitialized }

        // Store config and callbacks — actual container creation happens in startContainer
        // because Apple Containerization creates and starts in one flow
        pendingConfigs[id] = config
        if let logCb = config.onLog {
            logCallbacks[id] = logCb
        }
        if let progressCb = config.onProgress {
            progressCallbacks[id] = progressCb
        }
    }

    func startContainer(id: String) async throws {
        guard var manager else { throw ContainerEngineError.notInitialized }
        guard let imageStore else { throw ContainerEngineError.notInitialized }
        guard let config = pendingConfigs.removeValue(forKey: id) else {
            throw ContainerEngineError.containerNotFound(id)
        }

        let onLog = logCallbacks.removeValue(forKey: id)
        let onProgress = progressCallbacks.removeValue(forKey: id)

        let stdoutWriter = DebugWriter(prefix: "\(id) stdout", onLine: onLog)
        let stderrWriter = DebugWriter(prefix: "\(id) stderr", onLine: onLog)

        let containerDir = imageStore.path
            .appendingPathComponent("containers")
            .appendingPathComponent(id)

        // Invalidate cached rootfs if image changed
        let imageRefFile = containerDir.appendingPathComponent(".image-ref")
        let hasExistingDir = FileManager.default.fileExists(atPath: containerDir.path)
        if hasExistingDir {
            let cachedRef = try? String(contentsOf: imageRefFile, encoding: .utf8)
            if cachedRef != config.image {
                debugLog("[AppleContainerRuntime] Cached rootfs image mismatch for \(id): cached=\(cachedRef ?? "nil"), requested=\(config.image) — invalidating cache")
                try? FileManager.default.removeItem(at: containerDir)
            }
        }
        let hasExistingRootfs = FileManager.default.fileExists(atPath: containerDir.path)

        debugLog("[AppleContainerRuntime] Creating container \(id) from \(config.image)\(hasExistingRootfs ? " (reusing cached rootfs)" : "")")

        // Build Apple Containerization mount objects
        var mounts: [Containerization.Mount] = []
        for (hostPath, containerPath) in config.volumes {
            // Detect ext4 disk images vs virtiofs shares
            if hostPath.hasSuffix(".img") {
                mounts.append(.block(
                    format: "ext4",
                    source: hostPath,
                    destination: containerPath,
                    runtimeOptions: [
                        "vzDiskImageCachingMode=cached",
                        "vzDiskImageSynchronizationMode=fsync",
                    ]
                ))
            } else {
                mounts.append(.share(source: hostPath, destination: containerPath))
            }
        }

        // Progress poller for rootfs extraction
        let estimatedContentBytes = config.estimatedContentBytes
        let containerDirPath = containerDir.path
        let startProgressPoller: () -> Task<Void, Never>? = {
            guard let onProgress else { return nil }
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
                    let progress = min(Double(allocatedSize) / Double(estimatedContentBytes), 0.99)
                    onProgress(progress)
                }
            }
        }
        var progressPoller = startProgressPoller()

        var container: LinuxContainer
        let rootfsFile = containerDir.appendingPathComponent("rootfs.ext4")
        let hasExistingRootfsFile = hasExistingRootfs && FileManager.default.fileExists(atPath: rootfsFile.path)

        if hasExistingRootfsFile {
            progressPoller?.cancel()
            onProgress?(1.0)
            do {
                let rootfsMount = Mount.block(
                    format: "ext4",
                    source: rootfsFile.path,
                    destination: "/",
                    options: []
                )
                let ociImage = try await imageStore.get(reference: config.image, pull: false)
                container = try await manager.create(
                    id,
                    image: ociImage,
                    rootfs: rootfsMount
                ) { containerConfig in
                    containerConfig.cpus = config.cpus
                    containerConfig.memoryInBytes = config.memoryInBytes
                    containerConfig.process.stdout = stdoutWriter
                    containerConfig.process.stderr = stderrWriter
                    if let command = config.command { containerConfig.process.arguments = command }
                    for (key, value) in config.env { containerConfig.process.environmentVariables.append("\(key)=\(value)") }
                    for mount in mounts { containerConfig.mounts.append(mount) }
                }
                try await container.create()
                try await container.start()
                debugLog("[AppleContainerRuntime] Reused cached rootfs for \(id)")
            } catch {
                debugLog("[AppleContainerRuntime] Cached rootfs unusable for \(id), re-extracting: \(error)")
                try? manager.releaseNetwork(id)
                try? FileManager.default.removeItem(at: containerDir)
                onProgress?(0.0)
                progressPoller = startProgressPoller()
                container = try await manager.create(
                    id, reference: config.image,
                    rootfsSizeInBytes: config.rootfsSizeInBytes
                ) { containerConfig in
                    containerConfig.cpus = config.cpus
                    containerConfig.memoryInBytes = config.memoryInBytes
                    containerConfig.process.stdout = stdoutWriter
                    containerConfig.process.stderr = stderrWriter
                    if let command = config.command { containerConfig.process.arguments = command }
                    for (key, value) in config.env { containerConfig.process.environmentVariables.append("\(key)=\(value)") }
                    for mount in mounts { containerConfig.mounts.append(mount) }
                }
                progressPoller?.cancel()
                onProgress?(1.0)
                try await container.create()
                try await container.start()
            }
        } else {
            if hasExistingRootfs {
                try? FileManager.default.removeItem(at: containerDir)
            }
            do {
                container = try await manager.create(
                    id, reference: config.image,
                    rootfsSizeInBytes: config.rootfsSizeInBytes
                ) { containerConfig in
                    containerConfig.cpus = config.cpus
                    containerConfig.memoryInBytes = config.memoryInBytes
                    containerConfig.process.stdout = stdoutWriter
                    containerConfig.process.stderr = stderrWriter
                    if let command = config.command { containerConfig.process.arguments = command }
                    for (key, value) in config.env { containerConfig.process.environmentVariables.append("\(key)=\(value)") }
                    for mount in mounts { containerConfig.mounts.append(mount) }
                }
            } catch {
                progressPoller?.cancel()
                throw error
            }
            progressPoller?.cancel()
            onProgress?(1.0)
            try await container.create()
            try await container.start()
        }

        // Record image reference for cache invalidation
        try? config.image.write(to: imageRefFile, atomically: true, encoding: .utf8)

        // Monitor container exit in background
        let containerId = id
        Task {
            do {
                let status = try await container.wait()
                debugLog("[AppleContainerRuntime] Container \(containerId) EXITED with code \(status.exitCode)")
                self.exitedContainers.insert(containerId)
            } catch {
                debugLog("[AppleContainerRuntime] Container \(containerId) wait error: \(error)")
                self.exitedContainers.insert(containerId)
            }
        }

        containers[id] = container
    }

    func stopContainer(id: String, timeout: Int) async throws {
        guard let container = containers[id] else { return }

        do {
            try await container.kill(SIGTERM)
        } catch {
            // Container may have already exited
        }

        var exited = exitedContainers.contains(id)
        if !exited {
            let polls = timeout * 2 // poll every 500ms
            for _ in 0..<polls {
                try? await Task.sleep(for: .milliseconds(500))
                if exitedContainers.contains(id) {
                    exited = true
                    break
                }
            }
        }

        if !exited {
            try? await container.kill(SIGKILL)
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(500))
                if exitedContainers.contains(id) { break }
            }
        }

        Task { try? await container.stop() }

        try? manager?.releaseNetwork(id)
        exitedContainers.remove(id)
        containers.removeValue(forKey: id)
    }

    func removeContainer(id: String) async throws {
        try? manager?.delete(id)
        containers.removeValue(forKey: id)
        exitedContainers.remove(id)
    }

    func execInContainer(id: String, command: [String]) async throws -> ExecResult {
        guard let container = containers[id] else {
            throw ContainerEngineError.containerNotFound(id)
        }

        let execId = "exec-\(UUID().uuidString.prefix(8).lowercased())"
        let proc = try await container.exec(execId) { config in
            config.arguments = command
            config.workingDirectory = "/"
        }
        try await proc.start()
        let status = try await proc.wait()
        try await proc.delete()

        return ExecResult(exitCode: status.exitCode, stdout: "", stderr: "")
    }

    func containerIP(id: String) async throws -> String? {
        guard let container = containers[id] else { return nil }
        return container.interfaces.first?.ipv4Address.address.description
    }

    func containerLogs(id: String) async throws -> AsyncStream<String> {
        // Apple Containerization forwards logs via the DebugWriter callbacks set during creation.
        // This method returns an empty stream since logs are already being forwarded.
        return AsyncStream { $0.finish() }
    }

    func cleanup() async throws {
        for (id, container) in containers {
            try? await container.kill(SIGKILL)
            try? await container.stop()
            try? manager?.delete(id)
        }
        containers.removeAll()
        exitedContainers.removeAll()
    }

    // MARK: - Additional API (used by ContainerEngine)

    /// Returns true if the container process has exited unexpectedly.
    func hasExited(id: String) -> Bool {
        exitedContainers.contains(id)
    }

    /// Returns a running container for waiting on ephemeral containers.
    func getContainer(id: String) -> LinuxContainer? {
        containers[id]
    }

    /// Deletes a container from the manager (used for ephemeral containers).
    func deleteFromManager(id: String) throws {
        try manager?.delete(id)
        containers.removeValue(forKey: id)
    }
}
