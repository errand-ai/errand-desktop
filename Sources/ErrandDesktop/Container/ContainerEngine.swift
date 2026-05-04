import Foundation
@preconcurrency import Network

/// Debug log to file since print() doesn't appear in menu bar apps.
func debugLog(_ message: String) {
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

/// Orchestrates container lifecycle across services using a pluggable ContainerRuntime.
/// Handles dependency ordering, health checks, environment building, and the bridge API.
actor ContainerEngine {

    // MARK: - Properties

    /// The active container runtime (Docker or Apple Containerization).
    private var runtime: (any ContainerRuntime)?

    /// Which runtime capability is currently active.
    private(set) var activeCapability: RuntimeCapability?

    /// Maps service IDs (e.g. "postgres") to container IDs.
    private var serviceContainerMap: [String: String] = [:]

    /// Tracks task-runner container exit statuses.
    private var taskContainerExitStatus: [String: (status: String, exitCode: Int?)] = [:]

    /// Collected logs per task container, available after exit.
    private var taskContainerLogs: [String: String] = [:]

    /// Per-container log stream continuations for bridge API.
    private var logContinuations: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]

    /// Storage manager for resolving data directory paths.
    private let storageManager = StorageManager()

    /// Bridge API auth token, set by AppState after BridgeServer init.
    var bridgeToken: String = ""

    /// Bridge API port, matches BridgeServer's listen port.
    var bridgePort: UInt16 = 9876

    /// The gateway IP for containers to reach the host.
    /// For Apple Containerization: vmnet gateway. For Docker: host.docker.internal.
    private var hostGatewayIP: String = "127.0.0.1"

    /// Credential encryption key from Keychain, injected into backend/worker containers.
    var credentialEncryptionKey: String = ""

    /// LiteLLM master key from Keychain, used as the LiteLLM API key for all containers.
    var litellmMasterKey: String = ""

    /// Stable LiteLLM salt key from Keychain, passed as `LITELLM_SALT_KEY` so that
    /// values encrypted in the database remain decryptable across container restarts.
    var litellmSaltKey: String = ""

    /// Scoped LiteLLM service key for Backend/Worker containers.
    private(set) var errandServiceKey: String = ""

    /// Scoped LiteLLM service key for Hindsight container.
    private(set) var hindsightServiceKey: String = ""

    /// Background tasks streaming Docker container logs, keyed by container ID.
    private var logStreamTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Configuration

    func setBridgeCredentials(token: String, port: UInt16) {
        self.bridgeToken = token
        self.bridgePort = port
    }

    func setCredentialEncryptionKey(_ key: String) {
        self.credentialEncryptionKey = key
    }

    func setLiteLLMMasterKey(_ key: String) {
        self.litellmMasterKey = key
    }

    func setLiteLLMSaltKey(_ key: String) {
        self.litellmSaltKey = key
    }

    // MARK: - Service Key Provisioning

    /// Provisions scoped LiteLLM API keys for Backend/Worker (errand) and Hindsight.
    /// Loads existing keys from Keychain, validates them against LiteLLM, and generates
    /// new keys if missing or stale. Falls back to the master key on failure.
    func provisionServiceKeys(config: AppConfig) async {
        guard !litellmMasterKey.isEmpty else {
            debugLog("[ContainerEngine] No master key set, skipping service key provisioning")
            return
        }

        // Resolve LiteLLM base URL based on runtime
        let litellmBaseURL: String
        if isDockerRuntime {
            litellmBaseURL = "http://localhost:\(config.litellmPort)"
        } else {
            // Apple Containerization: use container IP directly
            guard let litellmContainerId = serviceContainerMap["litellm"] else {
                debugLog("[ContainerEngine] LiteLLM container not found, falling back to master key")
                errandServiceKey = litellmMasterKey
                hindsightServiceKey = litellmMasterKey
                return
            }
            if let rt = runtime, let ip = try? await rt.containerIP(id: litellmContainerId) {
                litellmBaseURL = "http://\(ip):4000"
            } else {
                debugLog("[ContainerEngine] Could not resolve LiteLLM container IP, falling back to master key")
                errandServiceKey = litellmMasterKey
                hindsightServiceKey = litellmMasterKey
                return
            }
        }

        debugLog("[ContainerEngine] Provisioning service keys via \(litellmBaseURL)")

        do {
            errandServiceKey = try await provisionKey(
                account: "litellm-errand-key",
                alias: "errand-services",
                metadata: ["purpose": "Backend and Worker LLM access"],
                litellmBaseURL: litellmBaseURL
            )
        } catch {
            debugLog("[ContainerEngine] Errand service key provisioning failed: \(error). Falling back to master key")
            errandServiceKey = litellmMasterKey
        }

        do {
            hindsightServiceKey = try await provisionKey(
                account: "litellm-hindsight-key",
                alias: "hindsight-services",
                metadata: ["purpose": "Hindsight LLM and embedding access"],
                litellmBaseURL: litellmBaseURL
            )
        } catch {
            debugLog("[ContainerEngine] Hindsight service key provisioning failed: \(error). Falling back to master key")
            hindsightServiceKey = litellmMasterKey
        }

        debugLog("[ContainerEngine] Service keys provisioned (errand=\(errandServiceKey == litellmMasterKey ? "master" : "scoped"), hindsight=\(hindsightServiceKey == litellmMasterKey ? "master" : "scoped"))")
    }

    /// Provisions a single service key: load from Keychain, validate, generate if needed.
    private func provisionKey(
        account: String,
        alias: String,
        metadata: [String: String],
        litellmBaseURL: String
    ) async throws -> String {
        // Try loading from Keychain
        if let existingKey = try KeychainManager.get(account: account) {
            if await validateKey(existingKey, litellmBaseURL: litellmBaseURL) {
                debugLog("[ContainerEngine] Key '\(alias)' loaded from Keychain and validated")
                return existingKey
            }
            // Stale key — delete and regenerate
            debugLog("[ContainerEngine] Key '\(alias)' is stale, regenerating")
            try KeychainManager.delete(account: account)
        }

        // Generate new key with retries
        let newKey = try await generateKey(
            alias: alias,
            metadata: metadata,
            litellmBaseURL: litellmBaseURL
        )
        try KeychainManager.set(account: account, value: newKey)
        debugLog("[ContainerEngine] Key '\(alias)' generated and stored in Keychain")
        return newKey
    }

    /// Validates a key against LiteLLM via GET /key/info.
    private func validateKey(_ key: String, litellmBaseURL: String) async -> Bool {
        guard let url = URL(string: "\(litellmBaseURL)/key/info?key=\(key)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(litellmMasterKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

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

    /// Generates a new key via POST /key/generate with retry.
    private func generateKey(
        alias: String,
        metadata: [String: String],
        litellmBaseURL: String,
        maxRetries: Int = 3
    ) async throws -> String {
        guard let url = URL(string: "\(litellmBaseURL)/key/generate") else {
            throw ContainerEngineError.keyGenerationFailed("Invalid URL")
        }

        let body: [String: Any] = [
            "key_alias": alias,
            "key_type": "default",
            "models": [] as [String],
            "metadata": metadata,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        for attempt in 1...maxRetries {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(litellmMasterKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
            request.timeoutInterval = 15

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ContainerEngineError.keyGenerationFailed("No HTTP response")
                }
                guard (200..<300).contains(http.statusCode) else {
                    let responseBody = String(data: data, encoding: .utf8) ?? ""
                    throw ContainerEngineError.keyGenerationFailed("HTTP \(http.statusCode): \(responseBody)")
                }

                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let key = json?["key"] as? String else {
                    throw ContainerEngineError.keyGenerationFailed("No 'key' field in response")
                }
                return key
            } catch where attempt < maxRetries {
                debugLog("[ContainerEngine] Key generation attempt \(attempt)/\(maxRetries) failed: \(error). Retrying...")
                try await Task.sleep(for: .seconds(2))
            }
        }

        throw ContainerEngineError.keyGenerationFailed("All \(maxRetries) attempts failed")
    }

    // MARK: - Runtime Management

    /// Sets the active container runtime. Called by AppState during initialization.
    func setRuntime(_ runtime: any ContainerRuntime, capability: RuntimeCapability) async throws {
        self.runtime = runtime
        self.activeCapability = capability

        // Set host gateway IP based on runtime type
        switch capability {
        case .docker:
            hostGatewayIP = "host.docker.internal"
        case .appleContainerization:
            if let appleRuntime = runtime as? AppleContainerRuntime {
                try await appleRuntime.ensureInitialized()
                hostGatewayIP = await appleRuntime.hostGatewayIP
            }
        }

        debugLog("[ContainerEngine] Runtime set to \(capability.displayName), hostGateway=\(hostGatewayIP)")
    }

    /// Whether the current runtime is Docker.
    var isDockerRuntime: Bool {
        activeCapability == .docker
    }

    // MARK: - Image Pulling

    /// Pulls an OCI image by reference.
    func pullImage(name: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let runtime else { throw ContainerEngineError.notInitialized }
        try await runtime.pullImage(reference: name, onProgress: onProgress)
    }

    /// Expands short-form image references to fully-qualified form.
    static func qualifyImageReference(_ ref: String) -> String {
        let slashParts = ref.split(separator: "/", maxSplits: 1)
        if slashParts.count >= 2 {
            let firstPart = String(slashParts[0])
            if firstPart.contains(".") || firstPart.contains(":") {
                return ref
            }
            return "docker.io/\(ref)"
        }
        return "docker.io/library/\(ref)"
    }

    /// Returns the fully-qualified OCI image reference for a service ID.
    func imageReference(for serviceId: String, config: AppConfig) -> String? {
        let specs = imageSpecs(for: [ServiceInfo(id: serviceId, displayName: "")], config: config)
        return specs[serviceId]
    }

    // MARK: - Callback Types

    typealias LogCallback = @Sendable (String) -> Void
    typealias ProgressCallback = @Sendable (Double) -> Void
    typealias StatusCallback = @Sendable (String, ServiceStatus, String?) -> Void

    // MARK: - Container Lifecycle

    /// Creates and starts a container via the active runtime.
    /// Returns the container ID and IP address.
    private func createAndStartContainer(
        image: String,
        env: [String: String],
        volumes: [String: String],
        ports: [Int: Int],
        command: [String]? = nil,
        entrypoint: [String]? = nil,
        shmSize: Int64? = nil,
        rootfsSizeInBytes: UInt64 = 4 * 1024 * 1024 * 1024,
        estimatedContentBytes: UInt64 = 500_000_000,
        serviceId: String? = nil,
        onLog: LogCallback? = nil,
        onPreparingProgress: ProgressCallback? = nil
    ) async throws -> (containerId: String, ip: String) {
        guard let runtime else { throw ContainerEngineError.notInitialized }

        let containerId = if let serviceId { "errand-\(serviceId)" } else { "errand-\(UUID().uuidString.prefix(8).lowercased())" }

        var config = ContainerConfig(
            image: image,
            env: env,
            ports: ports,
            volumes: volumes,
            command: command,
            network: "errand",
            onLog: onLog,
            onProgress: onPreparingProgress,
            rootfsSizeInBytes: rootfsSizeInBytes,
            estimatedContentBytes: estimatedContentBytes
        )
        config.entrypoint = entrypoint
        config.shmSize = shmSize

        try await runtime.createContainer(id: containerId, config: config)
        try await runtime.startContainer(id: containerId)

        let ip = try await runtime.containerIP(id: containerId) ?? "127.0.0.1"
        debugLog("[ContainerEngine] Container \(containerId) started, ip=\(ip)")

        // For Docker, stream container logs to the onLog callback in a background task.
        // Apple Containerization handles this via DebugWriter during container creation.
        if isDockerRuntime, let onLog, let dockerRuntime = runtime as? DockerRuntime {
            let cid = containerId
            logStreamTasks[cid] = Task {
                do {
                    let stream = try await dockerRuntime.containerLogs(id: cid)
                    for await line in stream {
                        onLog(line)
                    }
                } catch {
                    debugLog("[ContainerEngine] Log stream error for \(cid): \(error)")
                }
            }
        }

        return (containerId, ip)
    }

    /// Stops a container by service ID.
    func stopContainer(serviceId: String, onLog: LogCallback? = nil) async throws {
        guard let runtime else { return }
        guard let containerId = serviceContainerMap[serviceId] else { return }

        // Cancel log streaming task before stopping
        logStreamTasks[containerId]?.cancel()
        logStreamTasks.removeValue(forKey: containerId)

        onLog?("Stopping \(serviceId)...")
        try await runtime.stopContainer(id: containerId, timeout: 10)
        onLog?("\(serviceId) stopped")

        serviceContainerMap.removeValue(forKey: serviceId)
        onLog?("\(serviceId) cleaned up")
    }

    /// Returns true if the container process for a service has exited unexpectedly.
    func hasExited(serviceId: String) async -> Bool {
        guard let containerId = serviceContainerMap[serviceId] else { return false }
        if let appleRuntime = runtime as? AppleContainerRuntime {
            return await appleRuntime.hasExited(id: containerId)
        }
        if let dockerRuntime = runtime as? DockerRuntime {
            do {
                let (running, _) = try await dockerRuntime.containerState(id: containerId)
                return !running
            } catch {
                return false
            }
        }
        return false
    }

    /// Runs a command inside a running container.
    func execInContainer(
        containerId: String,
        command: [String]
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let runtime else { throw ContainerEngineError.notInitialized }
        let result = try await runtime.execInContainer(id: containerId, command: command)
        return (result.exitCode, result.stdout, result.stderr)
    }

    // MARK: - Dependency-Ordered Startup

    /// Starts all services in dependency order, waiting for each to become healthy.
    func startAll(services: [ServiceInfo], config: AppConfig, onStatus: StatusCallback? = nil, onLog: (@Sendable (String, String) -> Void)? = nil, onPreparingProgress: (@Sendable (String, Double) -> Void)? = nil) async throws -> [ServiceInfo] {
        guard runtime != nil else { throw ContainerEngineError.notInitialized }

        var services = services
        let images = imageSpecs(for: services, config: config)

        var skipServices = Set<String>()
        if !config.deployLiteLLM { skipServices.insert("litellm") }
        if !config.useHindsight { skipServices.insert("hindsight") }
        if !config.useGoogleDrive { skipServices.insert("gdrive-mcp") }
        if !config.useOneDrive { skipServices.insert("onedrive-mcp") }

        let allServiceIds = serviceDependencies.keys.filter { !skipServices.contains($0) }
        var serviceIPs: [String: String] = [:]
        var completed = Set<String>()
        var failed = Set<String>()

        // Mark already-running services as completed
        for serviceId in allServiceIds {
            guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
            if services[idx].status == .running, serviceContainerMap[serviceId] != nil {
                if let ip = services[idx].containerIP {
                    serviceIPs[serviceId] = ip
                }
                completed.insert(serviceId)
            }
        }

        // Mark skipped services as resolved so dependency checks pass,
        // but track them separately so they don't affect the loop termination count.
        var resolved = Set<String>()
        for serviceId in skipServices {
            resolved.insert(serviceId)
        }

        // Use an async stream to decouple task spawning from result collection.
        // Each service runs as an unstructured Task, posts its result to the stream.
        let (resultStream, resultContinuation) = AsyncStream<Result<(String, ServiceInfo), Error>>.makeStream()
        var inFlight = Set<String>()

        /// Spawns tasks for services whose dependencies are now satisfied.
        func spawnReady() {
            let ready = allServiceIds.filter { id in
                !completed.contains(id) && !failed.contains(id) && !inFlight.contains(id) &&
                (serviceDependencies[id] ?? []).allSatisfy { completed.contains($0) || resolved.contains($0) }
            }
            for serviceId in ready {
                guard let idx = services.firstIndex(where: { $0.id == serviceId }) else { continue }
                guard let imageName = images[serviceId] else { continue }

                inFlight.insert(serviceId)
                let serviceSnapshot = services[idx]
                let ipsSnapshot = serviceIPs

                Task {
                    do {
                        let result = try await self.startSingleService(
                            serviceId: serviceId,
                            service: serviceSnapshot,
                            imageName: imageName,
                            config: config,
                            serviceIPs: ipsSnapshot,
                            onStatus: onStatus,
                            onLog: onLog,
                            onPreparingProgress: onPreparingProgress
                        )
                        resultContinuation.yield(.success(result))
                    } catch {
                        resultContinuation.yield(.failure(error))
                    }
                }
            }
        }

        // Seed the initial batch of services with no dependencies.
        spawnReady()

        // As each service completes, immediately check if new services are unblocked.
        for await result in resultStream {
            switch result {
            case .success(let (serviceId, updatedService)):
                inFlight.remove(serviceId)
                if let idx = services.firstIndex(where: { $0.id == serviceId }) {
                    services[idx] = updatedService
                }
                if updatedService.status == .running || updatedService.status == .stopped {
                    completed.insert(serviceId)
                    if let ip = updatedService.containerIP {
                        serviceIPs[serviceId] = ip
                    }
                } else {
                    failed.insert(serviceId)
                }
            case .failure(let error):
                if let engineError = error as? ContainerEngineError,
                   case .healthCheckTimeout(let serviceId) = engineError {
                    inFlight.remove(serviceId)
                    failed.insert(serviceId)
                    debugLog("[ContainerEngine] Service \(serviceId) failed, continuing with remaining services")
                }
            }

            // Spawn any services that are now unblocked by this completion.
            spawnReady()

            // If all services are done, close the stream.
            if completed.count + failed.count >= allServiceIds.count {
                resultContinuation.finish()
            }
        }

        return services
    }

    /// Starts a single service: pull, create, start, wait for healthy/exit.
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
        guard let runtime else { throw ContainerEngineError.notInitialized }
        var service = service

        try Task.checkCancellation()

        service.status = .pulling
        onStatus?(serviceId, .pulling, nil)

        debugLog("[ContainerEngine] Pulling image for \(serviceId): \(imageName)")
        let progressCb: ProgressCallback? = onPreparingProgress.map { handler in
            let sid = serviceId
            return { progress in handler(sid, progress) }
        }
        try await runtime.pullImage(reference: imageName, onProgress: nil)
        debugLog("[ContainerEngine] Pull complete for \(serviceId)")

        try Task.checkCancellation()

        service.status = .preparing
        onStatus?(serviceId, .preparing, nil)

        let env = buildEnv(for: serviceId, config: config, serviceIPs: serviceIPs)
        let volumes = buildVolumes(for: serviceId, config: config)

        let logCb: LogCallback? = onLog.map { handler in
            let sid = serviceId
            return { line in handler(sid, line) }
        }
        let command = commandOverride(for: serviceId)

        let (containerId, ip) = try await createAndStartContainer(
            image: imageName,
            env: env,
            volumes: volumes,
            ports: portMappings(for: serviceId, config: config),
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
            debugLog("[ContainerEngine] Waiting for ephemeral container \(serviceId) to complete...")

            // For Docker: poll container status until exited
            // For Apple: use container.wait()
            let exitCode = try await waitForContainerExit(containerId: containerId, timeout: 300)
            debugLog("[ContainerEngine] Ephemeral container \(serviceId) exited with code \(exitCode)")

            try? await runtime.stopContainer(id: containerId, timeout: 5)
            try? await runtime.removeContainer(id: containerId)
            serviceContainerMap.removeValue(forKey: serviceId)

            if exitCode == 0 {
                service.status = .stopped
                onStatus?(serviceId, .stopped, nil)
            } else {
                service.status = .error
                onStatus?(serviceId, .error, nil)
                throw ContainerEngineError.migrationFailed(exitCode: exitCode)
            }
        } else {
            let healthy = try await waitForHealthy(service: service, config: config, timeoutSeconds: 120)
            if healthy {
                if serviceId == "postgres", let cid = service.containerId {
                    await ensureDatabase("errand", containerId: cid)
                    await ensureDatabase("litellm", containerId: cid)
                    await ensureDatabase("hindsight", containerId: cid)
                    await ensureExtension("vector", database: "hindsight", containerId: cid)
                }
                if serviceId == "litellm", config.deployLiteLLM {
                    await provisionServiceKeys(config: config)
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

    /// Waits for a container to exit and returns its exit code.
    private func waitForContainerExit(containerId: String, timeout: Int) async throws -> Int {
        if let appleRuntime = runtime as? AppleContainerRuntime,
           let container = await appleRuntime.getContainer(id: containerId) {
            let status = try await container.wait()
            return Int(status.exitCode)
        }

        // For Docker: poll container state via inspect API until no longer running
        if let dockerRuntime = runtime as? DockerRuntime {
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while Date() < deadline {
                let state = try await dockerRuntime.containerState(id: containerId)
                if !state.running {
                    return state.exitCode
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw ContainerEngineError.healthCheckTimeout(containerId)
        }

        throw ContainerEngineError.notInitialized
    }

    // MARK: - Single Service Start

    func startService(
        _ service: ServiceInfo,
        config: AppConfig,
        serviceIPs: [String: String],
        onStatus: StatusCallback? = nil,
        onLog: (@Sendable (String, String) -> Void)? = nil,
        onPreparingProgress: (@Sendable (String, Double) -> Void)? = nil
    ) async throws -> ServiceInfo {
        guard let runtime else { throw ContainerEngineError.notInitialized }
        var service = service

        guard let imageName = imageReference(for: service.id, config: config) else {
            throw ContainerEngineError.healthCheckTimeout(service.id)
        }

        service.status = .pulling
        onStatus?(service.id, .pulling, nil)
        try await runtime.pullImage(reference: imageName, onProgress: nil)

        service.status = .preparing
        onStatus?(service.id, .preparing, nil)

        let env = buildEnv(for: service.id, config: config, serviceIPs: serviceIPs)
        let volumes = buildVolumes(for: service.id, config: config)

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
            volumes: volumes,
            ports: portMappings(for: service.id, config: config),
            command: commandOverride(for: service.id),
            entrypoint: entrypointOverride(for: service.id),
            shmSize: shmSizeOverride(for: service.id),
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

        let healthy = try await waitForHealthy(service: service, config: config, timeoutSeconds: 120)
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

    // MARK: - Reverse-Order Shutdown

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

    func createTaskContainer(image: String, env: [String: String], files: [String: String]) async throws -> String {
        guard let runtime else { throw ContainerEngineError.notInitialized }

        let qualifiedImage = Self.qualifyImageReference(image)
        debugLog("[BridgeServer] createTaskContainer image=\(image) → \(qualifiedImage)")
        try await runtime.pullImage(reference: qualifiedImage, onProgress: nil)

        let containerId = "task-\(UUID().uuidString.prefix(8).lowercased())"

        // Write input files to a host directory for mounting at /workspace.
        // Docker (Colima) only shares $HOME by default, so use ~/Library/Application Support
        // instead of the system temp dir which lives under /var/folders.
        let taskBaseDir = taskScratchDir(for: containerId)
        let workspaceDir = taskBaseDir.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        for (filename, content) in files {
            let filePath = workspaceDir.appendingPathComponent(filename)
            try content.write(to: filePath, atomically: true, encoding: .utf8)
        }

        // Create an empty output directory for result.json.
        // Set world-writable permissions so the container user can write result.json
        // via bind mounts on systems where macOS→Linux UID mapping is limited.
        let outputDir = taskBaseDir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        chmod(workspaceDir.path, 0o777)
        chmod(outputDir.path, 0o777)

        let config = ContainerConfig(
            image: qualifiedImage,
            env: env,
            volumes: [
                workspaceDir.path: "/workspace",
                outputDir.path: "/output",
            ],
            network: "errand",
            cpus: 2,
            // Task-runner needs headroom for the Python interpreter, OpenAI/Anthropic
            // SDKs, an MCP client, the tool catalog, and buffering for a 16k-token
            // LLM context. 256 MiB OOM-kills the container (exit 137) on real tasks.
            memoryInBytes: 2 * 1024 * 1024 * 1024,
            rootfsSizeInBytes: 2 * 1024 * 1024 * 1024
        )

        try await runtime.createContainer(id: containerId, config: config)
        try await runtime.startContainer(id: containerId)

        taskContainerExitStatus[containerId] = (status: "running", exitCode: nil)

        // Monitor container exit in the background
        Task {
            await self.monitorTaskContainerExit(containerId: containerId)
        }

        return containerId
    }

    /// Monitors a task container for exit — uses Apple container.wait() when available,
    /// falls back to polling Docker inspect API.
    private func monitorTaskContainerExit(containerId: String) async {
        if let appleRuntime = runtime as? AppleContainerRuntime,
           let container = await appleRuntime.getContainer(id: containerId) {
            do {
                let exitStatus = try await container.wait()
                recordTaskContainerExit(id: containerId, exitCode: Int(exitStatus.exitCode))
            } catch {
                recordTaskContainerExit(id: containerId, exitCode: -1)
            }
        } else if let dockerRuntime = runtime as? DockerRuntime {
            // Docker: poll container state via inspect API
            while true {
                try? await Task.sleep(for: .seconds(2))
                // Stop if already recorded (e.g. by containerStatus eager check or removal)
                if let existing = taskContainerExitStatus[containerId], existing.status == "exited" {
                    break
                }
                if taskContainerExitStatus[containerId] == nil {
                    break  // container was already removed
                }
                do {
                    let state = try await dockerRuntime.containerState(id: containerId)
                    if !state.running {
                        // Capture container logs before recording exit
                        if taskContainerLogs[containerId] == nil,
                           let logs = try? await dockerRuntime.containerLogsTail(id: containerId, lines: 500) {
                            taskContainerLogs[containerId] = logs
                        }
                        recordTaskContainerExit(id: containerId, exitCode: state.exitCode)
                        break
                    }
                } catch {
                    // Container may have been removed already — only record if still tracked as running
                    if let existing = taskContainerExitStatus[containerId], existing.status == "running" {
                        recordTaskContainerExit(id: containerId, exitCode: -1)
                    }
                    break
                }
            }
        }
    }

    private func recordTaskContainerExit(id: String, exitCode: Int) {
        debugLog("[ContainerEngine] Task container \(id) exited with code \(exitCode)")
        taskContainerExitStatus[id] = (status: "exited", exitCode: exitCode)
        logContinuations[id]?.finish()
        logContinuations.removeValue(forKey: id)
    }

    func containerStatus(_ id: String) async throws -> (status: String, exitCode: Int?) {
        guard var status = taskContainerExitStatus[id] else {
            throw ContainerEngineError.containerNotFound(id)
        }

        // If monitor hasn't caught up yet, check Docker directly
        if status.status == "running", let dockerRuntime = runtime as? DockerRuntime {
            if let state = try? await dockerRuntime.containerState(id: id), !state.running {
                // Capture logs before recording exit
                if let logs = try? await dockerRuntime.containerLogsTail(id: id, lines: 500) {
                    taskContainerLogs[id] = logs
                }
                recordTaskContainerExit(id: id, exitCode: state.exitCode)
                status = (status: "exited", exitCode: state.exitCode)
            }
        }

        return status
    }

    func containerLogs(_ id: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let runtime else { throw ContainerEngineError.notInitialized }
        guard taskContainerExitStatus[id] != nil else {
            throw ContainerEngineError.containerNotFound(id)
        }

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        logContinuations[id] = continuation

        // Pipe actual container logs into the SSE stream
        if let dockerRuntime = runtime as? DockerRuntime {
            Task {
                do {
                    let dockerStream = try await dockerRuntime.containerLogs(id: id)
                    for await line in dockerStream {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        } else if let appleRuntime = runtime as? AppleContainerRuntime {
            Task {
                do {
                    let appleStream = try await appleRuntime.containerLogs(id: id)
                    for await line in appleStream {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return stream
    }

    func readContainerLogs(_ id: String) async throws -> String {
        guard taskContainerExitStatus[id] != nil else {
            throw ContainerEngineError.containerNotFound(id)
        }
        return taskContainerLogs[id] ?? ""
    }

    func readContainerOutput(_ id: String) async throws -> String {
        guard taskContainerExitStatus[id] != nil else {
            throw ContainerEngineError.containerNotFound(id)
        }

        let outputFile = taskScratchDir(for: id)
            .appendingPathComponent("output/result.json")

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw ContainerEngineError.outputNotFound(id)
        }

        return try String(contentsOf: outputFile, encoding: .utf8)
    }

    func stopAndRemoveContainer(_ id: String) async throws {
        guard let runtime else { throw ContainerEngineError.notInitialized }

        try? await runtime.stopContainer(id: id, timeout: 10)
        try? await runtime.removeContainer(id: id)

        taskContainerExitStatus.removeValue(forKey: id)
        taskContainerLogs.removeValue(forKey: id)
        logContinuations[id]?.finish()
        logContinuations.removeValue(forKey: id)

        try? FileManager.default.removeItem(at: taskScratchDir(for: id))
    }

    // MARK: - Private Helpers

    /// Returns the scratch directory for a task container's workspace and output files.
    /// Uses ~/Library/Application Support/ErrandDesktop/tasks/ so that Docker (Colima)
    /// can bind-mount the paths (Colima only shares $HOME by default).
    private nonisolated func taskScratchDir(for containerId: String) -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ErrandDesktop/tasks/\(containerId)")
    }

    /// Rootfs size for Apple Containerization (ignored by Docker).
    private func rootfsSize(for serviceId: String) -> UInt64 {
        switch serviceId {
        case "litellm":    return 8 * 1024 * 1024 * 1024
        case "hindsight":  return 8 * 1024 * 1024 * 1024
        case "playwright": return 4 * 1024 * 1024 * 1024
        case "backend":    return 4 * 1024 * 1024 * 1024
        default:           return 2 * 1024 * 1024 * 1024
        }
    }

    /// Estimated content size for Apple Containerization progress (ignored by Docker).
    private func estimatedContentSize(for serviceId: String) -> UInt64 {
        switch serviceId {
        case "litellm":    return 1_500_000_000
        case "hindsight":  return 3_000_000_000
        case "playwright": return 1_500_000_000
        case "backend":    return   550_000_000
        case "migrate":    return   550_000_000
        case "postgres":   return   450_000_000
        case "valkey":     return    15_000_000
        default:           return   500_000_000
        }
    }

    private func commandOverride(for serviceId: String) -> [String]? {
        switch serviceId {
        case "migrate":
            return ["alembic", "upgrade", "head"]
        case "playwright":
            // Start Xvfb (virtual display) before the MCP server for non-headless mode.
            //
            // Apple Containerization reuses the rootfs across container restarts, so
            // /tmp/.X99-lock and /tmp/.X11-unix/X99 from a previous Xvfb process can
            // survive and make the next Xvfb refuse to start with "Server is already
            // active for display 99". Scrub the stale lock and socket first.
            //
            // Then poll for the X11 socket rather than a fixed sleep — Xvfb startup
            // time varies by host.
            let script = "rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null; Xvfb :99 -screen 0 1920x1080x24 -ac -nolisten tcp & for i in $(seq 1 50); do [ -S /tmp/.X11-unix/X99 ] && break; sleep 0.1; done; [ -S /tmp/.X11-unix/X99 ] || { echo 'Xvfb failed to create display socket' >&2; exit 1; }; DISPLAY=:99 exec node /app/cli.js --browser chromium --no-sandbox --isolated --port 3000 --host 0.0.0.0 --allowed-hosts '*'"
            if isDockerRuntime {
                // Docker: entrypoint=["sh","-c"] via entrypointOverride(), Cmd is the script.
                return [script]
            }
            // Apple: no entrypoint mechanism, full command needed.
            return ["sh", "-c", script]
        case "litellm":
            // Docker image has entrypoint (docker/prod_entrypoint.sh) that invokes litellm,
            // so Cmd only provides arguments. Apple Containerization has no entrypoint
            // mechanism, so needs the full command.
            if isDockerRuntime {
                return ["--config", "/etc/litellm/config.yaml", "--port", "4000", "--host", "0.0.0.0"]
            }
            return ["litellm", "--config", "/etc/litellm/config.yaml", "--port", "4000", "--host", "0.0.0.0"]
        default:
            return nil
        }
    }

    private func entrypointOverride(for serviceId: String) -> [String]? {
        guard isDockerRuntime else { return nil }
        switch serviceId {
        case "playwright":
            return ["sh", "-c"]
        default:
            return nil
        }
    }

    private func shmSizeOverride(for serviceId: String) -> Int64? {
        switch serviceId {
        case "playwright":
            return 2 * 1024 * 1024 * 1024  // 2GB
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
            case "backend", "migrate":
                images[service.id] = "ghcr.io/errand-ai/errand:\(config.contentManagerImageTag)"
            case "litellm":
                images["litellm"] = "ghcr.io/berriai/litellm-database:main-v1.81.3-stable"
            case "hindsight":
                images["hindsight"] = "ghcr.io/vectorize-io/hindsight:0.4.13"
            case "gdrive-mcp":
                images["gdrive-mcp"] = "ghcr.io/devops-consultants/google-drive-mcp-server:latest"
            case "onedrive-mcp":
                images["onedrive-mcp"] = "ghcr.io/devops-consultants/one-drive-mcp-server:latest"
            case "playwright":
                images["playwright"] = "mcr.microsoft.com/playwright/mcp:latest"
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

        // For Docker runtime, containers use container names for DNS resolution
        // For Apple runtime, they use IP addresses
        let resolveHost: (String) -> String? = { [self] sid in
            if self.isDockerRuntime {
                return "errand-\(sid)"
            } else {
                return serviceIPs[sid]
            }
        }

        switch serviceId {
        case "postgres":
            env["POSTGRES_USER"] = "postgres"
            env["POSTGRES_PASSWORD"] = "postgres"
            env["POSTGRES_DB"] = "errand"
            env["PGDATA"] = "/var/lib/postgresql/data/pgdata"

        case "valkey":
            env["VALKEY_SAVE"] = "60 1"

        case "migrate":
            if let pgHost = resolveHost("postgres") {
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgHost):5432/errand"
            }

        case "backend":
            if let pgHost = resolveHost("postgres") {
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgHost):5432/errand"
            }
            if let vkHost = resolveHost("valkey") {
                env["VALKEY_URL"] = "redis://\(vkHost):6379"
            }
            env["PORT"] = "\(config.backendPort)"
            if let litellmHost = resolveHost("litellm"), config.deployLiteLLM {
                env["LLM_PROVIDER_0_NAME"] = "LiteLLM"
                env["LLM_PROVIDER_0_BASE_URL"] = "http://\(litellmHost):4000"
                env["LLM_PROVIDER_0_API_KEY"] = errandServiceKey.isEmpty ? litellmMasterKey : errandServiceKey
            } else if !config.llmProviderBaseURL.isEmpty {
                env["LLM_PROVIDER_0_NAME"] = config.llmProviderName
                env["LLM_PROVIDER_0_BASE_URL"] = config.llmProviderBaseURL
                env["LLM_PROVIDER_0_API_KEY"] = config.llmProviderAPIKey
            }
            if !credentialEncryptionKey.isEmpty {
                env["CREDENTIAL_ENCRYPTION_KEY"] = credentialEncryptionKey
            }
            // Hindsight: HINDSIGHT_BASE_URL for server's own API calls,
            // HINDSIGHT_URL + HINDSIGHT_BANK_ID for TaskManager to inject into task-runners
            if let hindsightHost = resolveHost("hindsight"), config.useHindsight {
                env["HINDSIGHT_BASE_URL"] = "http://\(hindsightHost):8888"
                env["HINDSIGHT_URL"] = "http://\(hindsightHost):8888/"
                env["HINDSIGHT_BANK_ID"] = "errand-tasks"
            }
            if let gdriveHost = resolveHost("gdrive-mcp"), config.useGoogleDrive {
                env["GDRIVE_MCP_URL"] = "http://\(gdriveHost):8080/mcp"
            }
            if let onedriveHost = resolveHost("onedrive-mcp"), config.useOneDrive {
                env["ONEDRIVE_MCP_URL"] = "http://\(onedriveHost):8080/mcp"
            }
            if let playwrightHost = resolveHost("playwright") {
                env["PLAYWRIGHT_MCP_URL"] = "http://\(playwrightHost):3000/mcp"
            }
            // Task-runner management via Bridge API
            env["CONTAINER_RUNTIME"] = "apple"
            env["CONTAINER_BRIDGE_URL"] = "http://\(hostGatewayIP):\(bridgePort)"
            env["CONTAINER_BRIDGE_TOKEN"] = bridgeToken
            env["TASK_RUNNER_IMAGE"] = "ghcr.io/errand-ai/errand-task-runner:\(config.contentManagerImageTag)"
            // Self-referencing URL for task-runners to call back to the server
            if isDockerRuntime {
                env["ERRAND_MCP_URL"] = "http://errand-backend:\(config.backendPort)/mcp"
            } else if let backendIP = resolveHost("backend") {
                env["ERRAND_MCP_URL"] = "http://\(backendIP):\(config.backendPort)/mcp"
            }
            // Telemetry
            env["ERRAND_CONTAINER_RUNTIME"] = isDockerRuntime ? "apple-docker" : "apple-container"

        case "litellm":
            env["HOST"] = "0.0.0.0"
            env["PORT"] = "4000"
            env["DATABASE_USERNAME"] = "postgres"
            env["DATABASE_PASSWORD"] = "postgres"
            if let pgHost = resolveHost("postgres") {
                env["DATABASE_HOST"] = pgHost
                env["DATABASE_URL"] = "postgresql://postgres:postgres@\(pgHost):5432/litellm"
            }
            env["DATABASE_NAME"] = "litellm"
            if !litellmMasterKey.isEmpty {
                env["PROXY_MASTER_KEY"] = litellmMasterKey
                env["LITELLM_MASTER_KEY"] = litellmMasterKey
                env["UI_USERNAME"] = "admin"
                env["UI_PASSWORD"] = litellmMasterKey
            }
            if !litellmSaltKey.isEmpty {
                env["LITELLM_SALT_KEY"] = litellmSaltKey
            }
            env["LITELLM_MODE"] = "PRODUCTION"
            env["LITELLM_PROXY_CONNECTION_TIMEOUT"] = "600"

        case "hindsight":
            if let pgHost = resolveHost("postgres") {
                env["HINDSIGHT_API_DATABASE_URL"] = "postgresql://postgres:postgres@\(pgHost):5432/hindsight"
            }
            env["HINDSIGHT_API_PORT"] = "8888"
            env["HINDSIGHT_API_HOST"] = "0.0.0.0"
            env["HINDSIGHT_CP_HOSTNAME"] = "0.0.0.0"
            env["HINDSIGHT_CP_DATAPLANE_API_URL"] = "http://127.0.0.1:8888"
            if let litellmHost = resolveHost("litellm"), config.deployLiteLLM {
                let litellmBase = "http://\(litellmHost):4000"
                let hKey = hindsightServiceKey.isEmpty ? litellmMasterKey : hindsightServiceKey
                // LiteLLM exposes an OpenAI-compatible API
                env["HINDSIGHT_API_LLM_PROVIDER"] = "openai"
                env["HINDSIGHT_API_LLM_BASE_URL"] = litellmBase
                env["HINDSIGHT_API_LLM_API_KEY"] = hKey
                // Only configure embeddings/reranker via LiteLLM if user selected an embedding model;
                // otherwise Hindsight uses its builtin embedding and rerank models.
                if !config.hindsightEmbeddingModel.isEmpty {
                    env["HINDSIGHT_API_EMBEDDINGS_PROVIDER"] = "openai"
                    env["HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL"] = litellmBase
                    env["HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY"] = hKey
                    env["HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL"] = config.hindsightEmbeddingModel
                    env["HINDSIGHT_API_RERANKER_PROVIDER"] = "flashrank"
                }
            } else if !config.llmProviderBaseURL.isEmpty {
                env["HINDSIGHT_API_LLM_PROVIDER"] = "openai"
                env["HINDSIGHT_API_LLM_BASE_URL"] = config.llmProviderBaseURL
                env["HINDSIGHT_API_LLM_API_KEY"] = config.llmProviderAPIKey
                if !config.hindsightEmbeddingModel.isEmpty {
                    env["HINDSIGHT_API_EMBEDDINGS_PROVIDER"] = "openai"
                    env["HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL"] = config.llmProviderBaseURL
                    env["HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY"] = config.llmProviderAPIKey
                    env["HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL"] = config.hindsightEmbeddingModel
                    env["HINDSIGHT_API_RERANKER_PROVIDER"] = "flashrank"
                }
            }
            if !config.hindsightLLMModel.isEmpty {
                env["HINDSIGHT_API_LLM_MODEL"] = config.hindsightLLMModel
            }

        default:
            break
        }

        return env
    }

    /// Builds volume mount mappings (host path → container path) for a service.
    /// Docker uses plain directories; Apple Containerization uses ext4 disk images.
    private func buildVolumes(for serviceId: String, config: AppConfig) -> [String: String] {
        switch serviceId {
        case "postgres":
            if isDockerRuntime {
                // Use a Docker named volume instead of a bind mount. Named volumes are
                // managed inside Docker's Linux VM, avoiding macOS permission issues
                // (chown failures) that occur with bind mounts on some systems.
                return ["errand-postgres-data": "/var/lib/postgresql/data"]
            } else {
                let diskPath = (try? storageManager.ensureDataDisk(for: "postgres", sizeInMB: 1024)) ?? ""
                return [diskPath: "/var/lib/postgresql/data"]
            }
        case "valkey":
            if isDockerRuntime {
                return ["errand-valkey-data": "/data"]
            } else {
                let diskPath = (try? storageManager.ensureDataDisk(for: "valkey", sizeInMB: 256)) ?? ""
                return [diskPath: "/data"]
            }
        case "litellm":
            return [storageManager.dataPath(for: "litellm"): "/etc/litellm"]
        case "hindsight":
            return [storageManager.dataPath(for: "hindsight"): "/data"]
        default:
            return [:]
        }
    }

    /// Returns port mappings for a service (host port → container port).
    /// Only used by Docker runtime — Apple Containerization uses PortForwarder.
    private func portMappings(for serviceId: String, config: AppConfig) -> [Int: Int] {
        guard isDockerRuntime else { return [:] }

        switch serviceId {
        case "postgres": return [config.postgresPort: 5432]
        case "valkey": return [config.valkeyPort: 6379]
        case "backend": return [config.backendPort: 8000]
        case "litellm": return [config.litellmPort: 4000]
        case "hindsight": return [config.hindsightPort: 9999, 8888: 8888]
        case "playwright": return [3000: 3000]
        default: return [:]
        }
    }

    // MARK: - Health Checks

    private func waitForHealthy(service: ServiceInfo, config: AppConfig, timeoutSeconds: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var attempts = 0

        debugLog("[ContainerEngine] Waiting for \(service.id) to become healthy (timeout: \(timeoutSeconds)s, ip: \(service.containerIP ?? "nil"), container: \(service.containerId ?? "nil"))")

        // For Docker: health check against localhost (ports are published)
        // For Apple: health check against container IP
        let healthHost: String
        if isDockerRuntime {
            healthHost = "127.0.0.1"
        } else {
            healthHost = service.containerIP ?? "127.0.0.1"
        }

        while Date() < deadline {
            attempts += 1
            if try await checkHealth(service: service, config: config, host: healthHost) {
                debugLog("[ContainerEngine] \(service.id) healthy after \(attempts) attempts")
                return true
            }
            if attempts <= 3 || attempts % 10 == 0 {
                debugLog("[ContainerEngine] \(service.id) health check attempt \(attempts) failed")
            }
            if attempts == 5, let containerId = service.containerId {
                await runDiagnostic(service: service.id, containerId: containerId)
            }
            try await Task.sleep(for: .seconds(2))
        }
        debugLog("[ContainerEngine] \(service.id) health check timed out after \(attempts) attempts (\(timeoutSeconds)s)")
        return false
    }

    private func runDiagnostic(service: String, containerId: String) async {
        do {
            let (exitCode, stdout, _) = try await execInContainer(containerId: containerId, command: ["ps", "aux"])
            debugLog("[ContainerEngine] DIAG \(service) ps exit=\(exitCode) stdout=\(stdout)")
        } catch {
            debugLog("[ContainerEngine] DIAG \(service) ps failed: \(error)")
        }
    }

    private func checkHealth(service: ServiceInfo, config: AppConfig, host: String) async throws -> Bool {
        let docker = isDockerRuntime
        switch service.id {
        case "postgres":
            if let containerId = service.containerId {
                return await execHealthCheck(containerId: containerId, command: ["pg_isready", "-U", "postgres"])
            }
            return await tcpCheck(host: host, port: docker ? config.postgresPort : 5432)
        case "valkey":
            if let containerId = service.containerId {
                return await execHealthCheck(containerId: containerId, command: ["valkey-cli", "ping"])
            }
            return await tcpCheck(host: host, port: docker ? config.valkeyPort : 6379)
        case "backend":
            return await httpCheck(host: host, port: docker ? config.backendPort : 8000, path: "/health")
        case "litellm":
            return await httpCheck(host: host, port: docker ? config.litellmPort : 4000, path: "/health/liveliness")
        case "hindsight":
            return await httpCheck(host: host, port: 8888, path: "/health")
        case "gdrive-mcp", "onedrive-mcp":
            // These services don't publish ports to the host — exec inside the container.
            if let containerId = service.containerId {
                return await execHealthCheck(containerId: containerId, command: [
                    "python3", "-c",
                    "import urllib.request; urllib.request.urlopen(\"http://localhost:8080/health\")"
                ])
            }
            return false
        case "playwright":
            return await tcpCheck(host: host, port: 3000)
        default:
            return true
        }
    }

    private func ensureDatabase(_ name: String, containerId: String) async {
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
    case keyGenerationFailed(String)

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
        case .keyGenerationFailed(let reason):
            "LiteLLM key generation failed: \(reason)"
        }
    }
}
