import Foundation

/// Docker Engine API implementation of the ContainerRuntime protocol.
/// Communicates with Docker via HTTP over Unix socket.
actor DockerRuntime: ContainerRuntime {

    private let client: DockerHTTPClient

    init(socketPath: String = "/var/run/docker.sock") {
        self.client = DockerHTTPClient(socketPath: socketPath)
    }

    /// Name of the Docker bridge network for inter-container communication.
    private let networkName = "errand"

    // MARK: - Network Management (Task 2.8)

    /// Ensures the `errand` bridge network exists, creating it if necessary.
    func ensureNetwork() async throws {
        // Check if network already exists
        let (_, statusCode) = try await client.request(
            method: "GET",
            path: "/networks/\(networkName)"
        )
        if statusCode == 200 { return }

        // Create the network
        let createBody: [String: Any] = [
            "Name": networkName,
            "Driver": "bridge",
            "CheckDuplicate": true,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: createBody)
        let (_, createStatus) = try await client.request(
            method: "POST",
            path: "/networks/create",
            body: bodyData
        )

        guard createStatus == 201 else {
            throw DockerError.networkError("Failed to create network '\(networkName)', status: \(createStatus)")
        }
        debugLog("[DockerRuntime] Created bridge network '\(networkName)'")
    }

    // MARK: - Image Pulling (Task 2.2)

    func pullImage(reference: String, onProgress: (@Sendable (Double) -> Void)?) async throws {
        // Normalize away the docker.io/ prefix — Docker API uses short names
        let normalized = normalizeImageReference(reference)
        let (imageName, tag) = splitImageReference(normalized)
        let encodedImage = imageName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? imageName
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
        let path = "/images/create?fromImage=\(encodedImage)&tag=\(encodedTag)"

        debugLog("[DockerRuntime] Pulling image \(normalized)")

        var layerProgress: [String: (current: Int64, total: Int64)] = [:]

        let stream = await client.requestStreaming(method: "POST", path: path)
        for try await chunk in stream {
            // Docker returns newline-delimited JSON objects
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                // Check for error
                if let error = json["error"] as? String {
                    throw DockerError.apiError(500, "Pull failed: \(error)")
                }

                // Track layer download progress
                if let id = json["id"] as? String,
                   let progressDetail = json["progressDetail"] as? [String: Any],
                   let current = progressDetail["current"] as? Int64,
                   let total = progressDetail["total"] as? Int64, total > 0 {
                    layerProgress[id] = (current, total)

                    let totalBytes: Int64 = layerProgress.values.reduce(0) { $0 + $1.total }
                    let currentBytes: Int64 = layerProgress.values.reduce(0) { $0 + $1.current }
                    if totalBytes > 0 {
                        onProgress?(Double(currentBytes) / Double(totalBytes))
                    }
                }
            }
        }

        onProgress?(1.0)
        debugLog("[DockerRuntime] Pull complete for \(normalized)")
    }

    // MARK: - Container Lifecycle (Tasks 2.3, 2.4)

    func createContainer(id: String, config: ContainerConfig) async throws {
        // Ensure network exists before creating containers
        try await ensureNetwork()

        // Docker stores images with short names — strip the docker.io prefix
        // that imageSpecs adds for Apple Containerization's OCI store.
        let image = normalizeImageReference(config.image)

        var body: [String: Any] = [
            "Image": image,
            "Hostname": id,
        ]

        // Environment variables
        if !config.env.isEmpty {
            body["Env"] = config.env.map { "\($0.key)=\($0.value)" }
        }

        // Command override
        if let command = config.command {
            body["Cmd"] = command
        }

        // Exposed ports (for documentation, actual binding is in HostConfig)
        var exposedPorts: [String: Any] = [:]
        for (_, containerPort) in config.ports {
            exposedPorts["\(containerPort)/tcp"] = [String: Any]()
        }
        if !exposedPorts.isEmpty {
            body["ExposedPorts"] = exposedPorts
        }

        // HostConfig
        var hostConfig: [String: Any] = [
            "NetworkMode": networkName,
        ]

        // Port bindings
        var portBindings: [String: Any] = [:]
        for (hostPort, containerPort) in config.ports {
            portBindings["\(containerPort)/tcp"] = [["HostPort": "\(hostPort)"]]
        }
        if !portBindings.isEmpty {
            hostConfig["PortBindings"] = portBindings
        }

        // Volume mounts (bind mounts)
        var binds: [String] = []
        for (hostPath, containerPath) in config.volumes {
            binds.append("\(hostPath):\(containerPath)")
        }
        if !binds.isEmpty {
            hostConfig["Binds"] = binds
        }

        body["HostConfig"] = hostConfig

        // Networking config — set the container's alias to its name for DNS
        body["NetworkingConfig"] = [
            "EndpointsConfig": [
                networkName: [
                    "Aliases": [id]
                ]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let encodedName = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let (responseData, statusCode) = try await client.request(
            method: "POST",
            path: "/containers/create?name=\(encodedName)",
            body: bodyData
        )

        // 409 = container with this name already exists — remove and retry
        if statusCode == 409 {
            debugLog("[DockerRuntime] Container \(id) already exists, removing and recreating")
            try await removeContainer(id: id)
            let (_, retryStatus) = try await client.request(
                method: "POST",
                path: "/containers/create?name=\(encodedName)",
                body: bodyData
            )
            guard retryStatus == 201 else {
                let msg = String(data: responseData, encoding: .utf8) ?? ""
                throw DockerError.apiError(retryStatus, "Failed to create container \(id): \(msg)")
            }
        } else if statusCode != 201 {
            let msg = String(data: responseData, encoding: .utf8) ?? ""
            throw DockerError.apiError(statusCode, "Failed to create container \(id): \(msg)")
        }

        debugLog("[DockerRuntime] Created container \(id)")
    }

    func startContainer(id: String) async throws {
        let (responseData, statusCode) = try await client.request(
            method: "POST",
            path: "/containers/\(id)/start"
        )

        // 304 = already started (not an error)
        guard statusCode == 204 || statusCode == 304 else {
            let msg = String(data: responseData, encoding: .utf8) ?? ""
            throw DockerError.apiError(statusCode, "Failed to start container \(id): \(msg)")
        }

        debugLog("[DockerRuntime] Started container \(id)")
    }

    func stopContainer(id: String, timeout: Int) async throws {
        let (_, statusCode) = try await client.request(
            method: "POST",
            path: "/containers/\(id)/stop?t=\(timeout)"
        )

        // 304 = already stopped, 404 = doesn't exist — both fine
        guard statusCode == 204 || statusCode == 304 || statusCode == 404 else {
            throw DockerError.apiError(statusCode, "Failed to stop container \(id)")
        }

        debugLog("[DockerRuntime] Stopped container \(id)")
    }

    func removeContainer(id: String) async throws {
        let (_, statusCode) = try await client.request(
            method: "DELETE",
            path: "/containers/\(id)?force=true&v=true"
        )

        // 404 = doesn't exist — fine
        guard statusCode == 204 || statusCode == 404 else {
            throw DockerError.apiError(statusCode, "Failed to remove container \(id)")
        }

        debugLog("[DockerRuntime] Removed container \(id)")
    }

    // MARK: - Exec (Task 2.5)

    func execInContainer(id: String, command: [String]) async throws -> ExecResult {
        // Step 1: Create exec instance
        let createBody: [String: Any] = [
            "AttachStdout": true,
            "AttachStderr": true,
            "Cmd": command,
        ]
        let createData = try JSONSerialization.data(withJSONObject: createBody)
        let (createResponse, createStatus) = try await client.request(
            method: "POST",
            path: "/containers/\(id)/exec",
            body: createData
        )

        guard createStatus == 201,
              let createJSON = try? JSONSerialization.jsonObject(with: createResponse) as? [String: Any],
              let execId = createJSON["Id"] as? String else {
            throw DockerError.execFailed("Failed to create exec instance in \(id)")
        }

        // Step 2: Start exec instance (captures output)
        let startBody: [String: Any] = [
            "Detach": false,
            "Tty": false,
        ]
        let startData = try JSONSerialization.data(withJSONObject: startBody)
        let (output, _) = try await client.request(
            method: "POST",
            path: "/exec/\(execId)/start",
            body: startData
        )

        // Step 3: Inspect exec for exit code
        let (inspectData, inspectStatus) = try await client.request(
            method: "GET",
            path: "/exec/\(execId)/json"
        )

        var exitCode: Int32 = -1
        if inspectStatus == 200,
           let inspectJSON = try? JSONSerialization.jsonObject(with: inspectData) as? [String: Any],
           let code = inspectJSON["ExitCode"] as? Int {
            exitCode = Int32(code)
        }

        // Parse Docker multiplexed stream output (stdout/stderr)
        let (stdout, stderr) = parseMultiplexedOutput(output)

        return ExecResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    // MARK: - Container IP (Task 2.6)

    func containerIP(id: String) async throws -> String? {
        let (data, statusCode) = try await client.request(
            method: "GET",
            path: "/containers/\(id)/json"
        )

        guard statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let networkSettings = json["NetworkSettings"] as? [String: Any],
              let networks = networkSettings["Networks"] as? [String: Any],
              let network = networks[networkName] as? [String: Any],
              let ip = network["IPAddress"] as? String, !ip.isEmpty else {
            return nil
        }

        return ip
    }

    // MARK: - Container State Inspection

    /// Inspects a Docker container and returns its running status and exit code.
    /// Uses `GET /containers/{id}/json` to read `State.Running` and `State.ExitCode`.
    func containerState(id: String) async throws -> (running: Bool, exitCode: Int) {
        let (data, statusCode) = try await client.request(
            method: "GET",
            path: "/containers/\(id)/json"
        )

        guard statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["State"] as? [String: Any] else {
            throw DockerError.containerNotFound(id)
        }

        let running = state["Running"] as? Bool ?? false
        let exitCode = state["ExitCode"] as? Int ?? -1
        return (running, exitCode)
    }

    // MARK: - Container Logs (Task 2.7)

    func containerLogs(id: String) async throws -> AsyncStream<String> {
        let stream = await client.requestStreaming(
            method: "GET",
            path: "/containers/\(id)/logs?follow=true&stdout=true&stderr=true&tail=100"
        )

        return AsyncStream { continuation in
            Task {
                do {
                    for try await chunk in stream {
                        // Docker log output may be multiplexed (8-byte header per frame)
                        let text = self.extractLogText(from: chunk)
                        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                            if !line.isEmpty {
                                continuation.yield(String(line))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    /// Fetch the last N lines of container logs (non-streaming, for debugging).
    func containerLogsTail(id: String, lines: Int = 50) async throws -> String {
        let (data, _) = try await client.request(
            method: "GET",
            path: "/containers/\(id)/logs?follow=false&stdout=true&stderr=true&tail=\(lines)"
        )
        // Strip Docker multiplexed log headers (8-byte frame headers)
        return extractLogText(from: data)
    }

    // MARK: - Cleanup (Task 2.9)

    func cleanup() async throws {
        // List all containers
        let (data, statusCode) = try await client.request(
            method: "GET",
            path: "/containers/json?all=true"
        )

        guard statusCode == 200,
              let containers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        for container in containers {
            guard let names = container["Names"] as? [String] else { continue }
            let matchesPrefix = names.contains { name in
                let clean = name.hasPrefix("/") ? String(name.dropFirst()) : name
                return clean.hasPrefix("errand-") || clean.hasPrefix("task-")
            }
            guard matchesPrefix, let containerId = container["Id"] as? String else { continue }

            try? await stopContainer(id: containerId, timeout: 5)
            try? await removeContainer(id: containerId)
        }

        debugLog("[DockerRuntime] Cleanup complete")
    }

    // MARK: - Helpers

    /// Strips the `docker.io/` or `docker.io/library/` prefix that the engine adds
    /// for Apple Containerization. Docker stores and matches images by short name.
    private func normalizeImageReference(_ ref: String) -> String {
        if ref.hasPrefix("docker.io/library/") {
            return String(ref.dropFirst("docker.io/library/".count))
        }
        if ref.hasPrefix("docker.io/") {
            return String(ref.dropFirst("docker.io/".count))
        }
        return ref
    }

    /// Splits "docker.io/library/postgres:16" into ("docker.io/library/postgres", "16").
    private func splitImageReference(_ ref: String) -> (String, String) {
        // Handle digest references (sha256:...)
        if ref.contains("@") {
            let parts = ref.split(separator: "@", maxSplits: 1)
            return (String(parts[0]), String(parts[1]))
        }

        // Split on the last colon that's after any "/" (to avoid splitting on port numbers)
        guard let lastSlash = ref.lastIndex(of: "/") else {
            // Simple name like "nginx:latest"
            let parts = ref.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                return (String(parts[0]), String(parts[1]))
            }
            return (ref, "latest")
        }

        let afterSlash = ref[ref.index(after: lastSlash)...]
        if let colonIdx = afterSlash.lastIndex(of: ":") {
            let imageName = String(ref[ref.startIndex..<colonIdx])
            let tag = String(ref[ref.index(after: colonIdx)...])
            return (imageName, tag)
        }

        return (ref, "latest")
    }

    /// Parses Docker multiplexed stream output into stdout and stderr strings.
    /// Docker exec with Tty=false uses an 8-byte header per frame:
    ///   [stream_type(1)][0(3)][size(4 big-endian)][payload(size)]
    /// stream_type: 1 = stdout, 2 = stderr
    private nonisolated func parseMultiplexedOutput(_ data: Data) -> (String, String) {
        var stdout = ""
        var stderr = ""
        var offset = 0

        while offset + 8 <= data.count {
            let streamType = data[offset]
            let size = Int(data[offset + 4]) << 24 | Int(data[offset + 5]) << 16 | Int(data[offset + 6]) << 8 | Int(data[offset + 7])
            offset += 8

            guard offset + size <= data.count else { break }
            let payload = String(data: data[offset..<(offset + size)], encoding: .utf8) ?? ""
            offset += size

            switch streamType {
            case 1: stdout += payload
            case 2: stderr += payload
            default: break
            }
        }

        // If parsing failed (no valid frames), treat entire output as stdout
        if stdout.isEmpty && stderr.isEmpty && !data.isEmpty {
            stdout = String(data: data, encoding: .utf8) ?? ""
        }

        return (stdout, stderr)
    }

    /// Extracts text from Docker log stream data, stripping multiplexed headers if present.
    private nonisolated func extractLogText(from data: Data) -> String {
        // Try multiplexed parsing first
        let (stdout, stderr) = parseMultiplexedOutput(data)
        if !stdout.isEmpty || !stderr.isEmpty {
            return stdout + stderr
        }
        // Fallback: plain text
        return String(data: data, encoding: .utf8) ?? ""
    }
}
