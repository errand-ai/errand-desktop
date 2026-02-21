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

    /// Credential encryption key from Keychain, injected into backend/worker containers.
    var credentialEncryptionKey: String = ""

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

        manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: vminitRef,
            imageStore: store,
            network: network
        )
    }

    /// Removes container directories left over from previous app sessions.
    private static func cleanupOrphanedContainers(imageStore: ImageStore) {
        let fm = FileManager.default
        let containersDir = imageStore.path.appendingPathComponent("containers")
        guard let entries = try? fm.contentsOfDirectory(atPath: containersDir.path) else { return }
        let orphans = entries.filter { $0.hasPrefix("errand-") || $0.hasPrefix("task-") }
        if !orphans.isEmpty {
            debugLog("[ContainerEngine] Cleaning up \(orphans.count) orphaned container(s)")
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

    /// Returns the fully-qualified OCI image reference for a service ID.
    func imageReference(for serviceId: String, config: AppConfig) -> String? {
        let specs = imageSpecs(for: [ServiceInfo(id: serviceId, displayName: "")], config: config)
        return specs[serviceId]
    }

    // MARK: - Container Creation & Start (Tasks 3.2, 3.3)

    /// Callback for forwarding container log lines to the UI.
    typealias LogCallback = @Sendable (String) -> Void

    /// Creates and starts a container, returning its ID and IP address.
    func createAndStartContainer(
        image: String,
        env: [String: String],
        mounts: [Containerization.Mount],
        ports: [Int: Int],
        command: [String]? = nil,
        onLog: LogCallback? = nil
    ) async throws -> (containerId: String, ip: String) {
        try await ensureInitialized()
        guard var manager else { throw ContainerEngineError.notInitialized }

        let containerId = "errand-\(UUID().uuidString.prefix(8).lowercased())"

        debugLog("[ContainerEngine] Creating container \(containerId) from \(image) with \(mounts.count) mount(s)")

        let stdoutWriter = DebugWriter(prefix: "\(containerId) stdout", onLine: onLog)
        let stderrWriter = DebugWriter(prefix: "\(containerId) stderr", onLine: onLog)

        let container = try await manager.create(
            containerId,
            reference: image,
            rootfsSizeInBytes: 4 * 1024 * 1024 * 1024
        ) { config in
            config.cpus = 2
            config.memoryInBytes = 1024 * 1024 * 1024
            config.process.stdout = stdoutWriter
            config.process.stderr = stderrWriter

            if let command {
                config.process.arguments = command
            }

            for (key, value) in env {
                config.process.environmentVariables.append("\(key)=\(value)")
            }

            for mount in mounts {
                config.mounts.append(mount)
            }
        }

        debugLog("[ContainerEngine] Container \(containerId) created, calling create()...")
        try await container.create()
        debugLog("[ContainerEngine] Container \(containerId) VZ created, calling start()...")
        try await container.start()

        let ip: String
        if let iface = container.interfaces.first {
            ip = iface.ipv4Address.address.description
            debugLog("[ContainerEngine] Container \(containerId) started, ip=\(ip), interfaces=\(container.interfaces.count)")
        } else {
            ip = "127.0.0.1"
            debugLog("[ContainerEngine] Container \(containerId) started, NO interfaces, falling back to 127.0.0.1")
        }

        // Monitor container exit in background to catch crashes
        Task {
            do {
                let status = try await container.wait()
                debugLog("[ContainerEngine] Container \(containerId) EXITED with code \(status.exitCode)")
            } catch {
                debugLog("[ContainerEngine] Container \(containerId) wait error: \(error)")
            }
        }

        containers[containerId] = container
        return (containerId, ip)
    }

    /// Stops a container by service ID: SIGTERM, wait 10s, then SIGKILL.
    func stopContainer(serviceId: String) async throws {
        guard let containerId = serviceContainerMap[serviceId],
              let container = containers[containerId] else {
            return
        }

        do {
            try await container.kill(SIGTERM)
        } catch {
            // Container may have already exited
        }

        // Wait up to 10 seconds for graceful shutdown, then force kill
        let graceful = Task {
            _ = try? await container.wait()
        }

        let didFinish = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await graceful.result
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !didFinish {
            try? await container.kill(SIGKILL)
            _ = try? await container.wait()
        }

        try? await container.stop()
        try? manager?.delete(containerId)
        containers.removeValue(forKey: containerId)
        serviceContainerMap.removeValue(forKey: serviceId)
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
    typealias StatusCallback = @Sendable (String, ServiceStatus) -> Void

    /// Starts all services in dependency order, waiting for each to become healthy.
    /// Returns the updated services array. Calls `onStatus` when each service's status changes.
    /// Calls `onLog` with (serviceId, line) for each container stdout/stderr line.
    func startAll(services: [ServiceInfo], config: AppConfig, onStatus: StatusCallback? = nil, onLog: (@Sendable (String, String) -> Void)? = nil) async throws -> [ServiceInfo] {
        var services = services
        try await ensureInitialized()

        let images = imageSpecs(for: services, config: config)

        // Build startup order, inserting LiteLLM before backend if enabled
        var order = serviceStartupOrder
        if config.litellmEnabled && services.contains(where: { $0.id == "litellm" }) {
            if let backendIdx = order.firstIndex(where: { $0.contains("backend") }) {
                order.insert(["litellm"], at: backendIdx)
            }
        }

        var serviceIPs: [String: String] = [:]

        for group in order {
            for serviceId in group {
                guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
                guard let imageName = images[serviceId] else { continue }

                services[idx].status = .pulling
                onStatus?(serviceId, .pulling)

                debugLog("[ContainerEngine] Pulling image for \(serviceId): \(imageName)")
                try await pullImage(name: imageName)
                debugLog("[ContainerEngine] Pull complete for \(serviceId)")

                services[idx].status = .starting
                onStatus?(serviceId, .starting)

                let env = buildEnv(for: serviceId, config: config, serviceIPs: serviceIPs)
                let mounts = try buildMountObjects(for: serviceId)

                let logCb: LogCallback? = onLog.map { handler in
                    let sid = serviceId
                    return { line in handler(sid, line) }
                }
                let command = commandOverride(for: serviceId)
                let (containerId, ip) = try await createAndStartContainer(
                    image: imageName,
                    env: env,
                    mounts: mounts,
                    ports: [:],
                    command: command,
                    onLog: logCb
                )

                services[idx].containerId = containerId
                services[idx].containerIP = ip
                serviceContainerMap[serviceId] = containerId
                serviceIPs[serviceId] = ip
            }

            // Wait for every service in this group to become healthy or complete
            for serviceId in group {
                guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
                let service = services[idx]

                if service.isEphemeral {
                    // Ephemeral containers: wait for exit instead of health-checking
                    guard let containerId = service.containerId,
                          let container = containers[containerId] else {
                        services[idx].status = .error
                        onStatus?(serviceId, .error)
                        throw ContainerEngineError.healthCheckTimeout(serviceId)
                    }

                    debugLog("[ContainerEngine] Waiting for ephemeral container \(serviceId) to complete...")
                    let exitStatus = try await container.wait()
                    debugLog("[ContainerEngine] Ephemeral container \(serviceId) exited with code \(exitStatus.exitCode)")

                    // Clean up the ephemeral container
                    try? await container.stop()
                    try? manager?.delete(containerId)
                    containers.removeValue(forKey: containerId)
                    serviceContainerMap.removeValue(forKey: serviceId)

                    if exitStatus.exitCode == 0 {
                        services[idx].status = .stopped
                        onStatus?(serviceId, .stopped)
                    } else {
                        services[idx].status = .error
                        onStatus?(serviceId, .error)
                        throw ContainerEngineError.migrationFailed(exitCode: Int(exitStatus.exitCode))
                    }
                } else {
                    let healthy = try await waitForHealthy(service: service, timeoutSeconds: 120)
                    if healthy {
                        services[idx].status = .running
                        onStatus?(serviceId, .running)
                    } else {
                        services[idx].status = .error
                        onStatus?(serviceId, .error)
                        throw ContainerEngineError.healthCheckTimeout(serviceId)
                    }
                }
            }
        }
        return services
    }

    // MARK: - Reverse-Order Shutdown (Task 3.6)

    /// Stops all services in reverse startup order.
    /// Returns the updated services array.
    func stopAll(services: [ServiceInfo]) async throws -> [ServiceInfo] {
        var services = services
        var order = serviceStartupOrder
        if services.contains(where: { $0.id == "litellm" && $0.containerId != nil }) {
            order.append(["litellm"])
        }

        for group in order.reversed() {
            for serviceId in group {
                guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
                guard services[idx].containerId != nil else { continue }

                services[idx].status = .stopping
                try await stopContainer(serviceId: serviceId)
                services[idx].status = .stopped
                services[idx].containerId = nil
                services[idx].containerIP = nil
                services[idx].healthCheckFailures = 0
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

        try await pullImage(name: image)

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
            reference: image,
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
                images["postgres"] = "docker.io/library/postgres:16-alpine"
            case "valkey":
                images["valkey"] = "docker.io/valkey/valkey:8-alpine"
            case "backend", "worker", "migrate":
                images[service.id] = "ghcr.io/errand-ai/errand-backend:\(config.contentManagerImageTag)"
            case "litellm":
                images["litellm"] = "ghcr.io/berriai/litellm:latest"
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
            env["POSTGRES_DB"] = "content_manager"
            env["PGDATA"] = "/var/lib/postgresql/data/pgdata"

        case "valkey":
            env["VALKEY_SAVE"] = "60 1"

        case "migrate":
            if let pgIP = serviceIPs["postgres"] {
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgIP):5432/content_manager"
            }

        case "backend":
            if let pgIP = serviceIPs["postgres"] {
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgIP):5432/content_manager"
            }
            if let vkIP = serviceIPs["valkey"] {
                env["VALKEY_URL"] = "redis://\(vkIP):6379"
            }
            env["PORT"] = "\(config.backendPort)"
            if !config.openaiAPIKey.isEmpty {
                env["OPENAI_API_KEY"] = config.openaiAPIKey
            }
            if !config.openaiBaseURL.isEmpty {
                env["OPENAI_BASE_URL"] = config.openaiBaseURL
            }
            if config.litellmEnabled, let litellmIP = serviceIPs["litellm"] {
                env["OPENAI_BASE_URL"] = "http://\(litellmIP):\(config.litellmPort)"
            }
            if !credentialEncryptionKey.isEmpty {
                env["CREDENTIAL_ENCRYPTION_KEY"] = credentialEncryptionKey
            }
            if !config.oidcDiscoveryURL.isEmpty {
                env["OIDC_DISCOVERY_URL"] = config.oidcDiscoveryURL
                env["OIDC_CLIENT_ID"] = config.oidcClientID
                env["OIDC_CLIENT_SECRET"] = config.oidcClientSecret
            }

        case "worker":
            if let pgIP = serviceIPs["postgres"] {
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgIP):5432/content_manager"
            }
            if let vkIP = serviceIPs["valkey"] {
                env["VALKEY_URL"] = "redis://\(vkIP):6379"
            }
            if let backendIP = serviceIPs["backend"] {
                env["BACKEND_MCP_URL"] = "http://\(backendIP):\(config.backendPort)/mcp"
            }
            if !config.openaiAPIKey.isEmpty {
                env["OPENAI_API_KEY"] = config.openaiAPIKey
            }
            if !config.openaiBaseURL.isEmpty {
                env["OPENAI_BASE_URL"] = config.openaiBaseURL
            }
            if !credentialEncryptionKey.isEmpty {
                env["CREDENTIAL_ENCRYPTION_KEY"] = credentialEncryptionKey
            }
            // Bridge API credentials so the worker can create task-runner containers
            env["CONTAINER_RUNTIME"] = "apple"
            env["CONTAINER_BRIDGE_URL"] = "http://host.containers.internal:\(bridgePort)"
            env["CONTAINER_BRIDGE_TOKEN"] = bridgeToken

        case "litellm":
            break

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
            return [.share(source: storageManager.dataPath(for: "litellm"), destination: "/app/config")]
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
            return await httpCheck(host: ip, port: 4000, path: "/health")
        case "worker":
            return true
        default:
            return true
        }
    }

    /// Runs a command inside the container and returns true if exit code is 0.
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
