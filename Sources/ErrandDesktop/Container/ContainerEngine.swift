import Foundation
import Containerization
import ContainerizationOCI
@preconcurrency import Network

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

    // MARK: - Configuration

    /// Sets the bridge API credentials that will be injected into the worker container.
    func setBridgeCredentials(token: String, port: UInt16) {
        self.bridgeToken = token
        self.bridgePort = port
    }

    // MARK: - Initialization

    /// Sets up the ContainerManager with a kernel and network.
    private func ensureInitialized() async throws {
        guard manager == nil else { return }

        imageStore = try await ImageStore.default

        let kernel = try await Kernel.defaultLinux
        let network = try ContainerManager.VmnetNetwork()

        manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: "ghcr.io/apple/containerization/vminit:0.13.0",
            network: network
        )
    }

    // MARK: - Image Pulling (Task 3.1)

    /// Pulls an OCI image by name. Caches locally via ImageStore.
    func pullImage(name: String) async throws {
        try await ensureInitialized()
        guard let imageStore else { throw ContainerEngineError.notInitialized }
        _ = try await imageStore.pull(reference: name)
    }

    // MARK: - Container Creation & Start (Tasks 3.2, 3.3)

    /// Creates and starts a container, returning its ID and IP address.
    func createAndStartContainer(
        image: String,
        env: [String: String],
        mounts: [String: String],
        ports: [Int: Int]
    ) async throws -> (containerId: String, ip: String) {
        try await ensureInitialized()
        guard var manager else { throw ContainerEngineError.notInitialized }

        let containerId = "errand-\(UUID().uuidString.prefix(8).lowercased())"

        let container = try await manager.create(
            containerId,
            reference: image,
            rootfsSizeInBytes: 4 * 1024 * 1024 * 1024
        ) { config in
            config.cpus = 2
            config.memoryInBytes = 512 * 1024 * 1024

            for (key, value) in env {
                config.process.environmentVariables.append("\(key)=\(value)")
            }

            for (hostPath, guestPath) in mounts {
                config.mounts.append(
                    Mount.share(source: hostPath, destination: guestPath)
                )
            }
        }

        try await container.create()
        try await container.start()

        let ip: String
        if let iface = container.interfaces.first {
            ip = iface.ipv4Address.address.description
        } else {
            ip = "127.0.0.1"
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

        return (Int32(status), "", "")
    }

    // MARK: - Dependency-Ordered Startup (Task 3.5)

    /// Starts all services in dependency order, waiting for each to become healthy.
    func startAll(services: inout [ServiceInfo], config: AppConfig) async throws {
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

                services[idx].status = .starting

                try await pullImage(name: imageName)

                let env = buildEnv(for: serviceId, config: config, serviceIPs: serviceIPs)
                let mounts = buildMounts(for: serviceId)

                let (containerId, ip) = try await createAndStartContainer(
                    image: imageName,
                    env: env,
                    mounts: mounts,
                    ports: [:]
                )

                services[idx].containerId = containerId
                services[idx].containerIP = ip
                serviceContainerMap[serviceId] = containerId
                serviceIPs[serviceId] = ip
            }

            // Wait for every service in this group to pass health checks
            for serviceId in group {
                guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
                let service = services[idx]

                let healthy = try await waitForHealthy(service: service, timeoutSeconds: 60)
                if healthy {
                    services[idx].status = .running
                } else {
                    services[idx].status = .error
                    throw ContainerEngineError.healthCheckTimeout(serviceId)
                }
            }
        }
    }

    // MARK: - Reverse-Order Shutdown (Task 3.6)

    /// Stops all services in reverse startup order.
    func stopAll(services: inout [ServiceInfo]) async throws {
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
                let exitCode = try await container.wait()
                await self.recordTaskContainerExit(id: containerId, exitCode: Int(exitCode))
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

    /// Maps service IDs to their OCI image references.
    private func imageSpecs(for services: [ServiceInfo], config: AppConfig) -> [String: String] {
        var images: [String: String] = [:]
        for service in services {
            switch service.id {
            case "postgres":
                images["postgres"] = "docker.io/library/postgres:16-alpine"
            case "valkey":
                images["valkey"] = "docker.io/valkey/valkey:8-alpine"
            case "backend", "worker":
                images[service.id] = "ghcr.io/errand-app/content-manager:\(config.contentManagerImageTag)"
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
            env["PGDATA"] = "/var/lib/postgresql/data"

        case "valkey":
            env["VALKEY_SAVE"] = "60 1"

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
            if !config.oidcDiscoveryURL.isEmpty {
                env["OIDC_DISCOVERY_URL"] = config.oidcDiscoveryURL
                env["OIDC_CLIENT_ID"] = config.oidcClientID
                env["OIDC_CLIENT_SECRET"] = config.oidcClientSecret
            }

        case "worker":
            if let backendIP = serviceIPs["backend"] {
                env["BACKEND_MCP_URL"] = "http://\(backendIP):\(config.backendPort)/mcp"
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

    /// Builds volume mount mappings (host path -> guest path) for a service.
    private func buildMounts(for serviceId: String) -> [String: String] {
        switch serviceId {
        case "postgres":
            return [storageManager.dataPath(for: "postgres"): "/var/lib/postgresql/data"]
        case "valkey":
            return [storageManager.dataPath(for: "valkey"): "/data"]
        case "litellm":
            return [storageManager.dataPath(for: "litellm"): "/app/config"]
        default:
            return [:]
        }
    }

    /// Polls health checks until the service is healthy or timeout.
    private func waitForHealthy(service: ServiceInfo, timeoutSeconds: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            if try await checkHealth(service: service) {
                return true
            }
            try await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// Single health check for a service.
    private func checkHealth(service: ServiceInfo) async throws -> Bool {
        guard let ip = service.containerIP else { return false }

        switch service.id {
        case "postgres":
            return await tcpCheck(host: ip, port: 5432)
        case "valkey":
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

    /// TCP connectivity check with 5s timeout.
    private func tcpCheck(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let queue = DispatchQueue(label: "engine-tcp-\(host):\(port)")
            var resumed = false

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
        }
    }
}
