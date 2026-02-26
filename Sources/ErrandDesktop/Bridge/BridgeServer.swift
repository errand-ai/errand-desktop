@preconcurrency import Network
import Foundation


/// Local HTTP server exposing the container bridge API for the worker.
/// Binds to the loopback interface only, authenticates via bearer token.
actor BridgeServer {
    private let containerEngine: ContainerEngine
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sh.errand.bridge-server")

    /// Bearer token for authenticating API requests.
    /// Generated at init; pass to worker container as CONTAINER_BRIDGE_TOKEN.
    let authToken: String

    init(containerEngine: ContainerEngine) {
        self.containerEngine = containerEngine
        self.authToken = UUID().uuidString
    }

    /// Start the HTTP server on the given port (all interfaces, so containers can reach it).
    func start(port: UInt16 = 9876) throws {
        let params = NWParameters.tcp

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw BridgeServerError.invalidPort
        }

        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("[BridgeServer] Listening on 0.0.0.0:\(port)")
            } else if case .failed(let error) = state {
                print("[BridgeServer] Failed: \(error)")
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection) }
        }

        listener.start(queue: queue)
    }

    /// Stop the HTTP server.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func accept(_ connection: NWConnection) async {
        connection.start(queue: queue)

        do {
            let request = try await receiveRequest(from: connection)

            // Unauthenticated: serves an auto-login page for the LiteLLM UI.
            if request.method == "GET" && request.path == "/litellm-login" {
                let response = handleLiteLLMLogin()
                try await send(response, on: connection)
                connection.cancel()
                return
            }

            guard authenticate(request) else {
                try await send(.unauthorized, on: connection)
                connection.cancel()
                return
            }

            // SSE log streaming is handled separately (keeps connection open)
            if request.method == "GET",
               let (id, action) = parseContainerRoute(request.path),
               action == "logs" {
                await streamLogs(id: id, on: connection)
                return
            }

            let response = await route(request)
            debugLog("[BridgeServer] \(request.method) \(request.path) → \(response.statusCode)")
            try await send(response, on: connection)
        } catch {
            debugLog("[BridgeServer] Request error: \(error)")
            try? await send(
                .error(500, "Internal Server Error", message: "\(error)"),
                on: connection
            )
        }

        connection.cancel()
    }

    // MARK: - HTTP I/O

    private func receiveRequest(from connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()

        for _ in 0..<10 {
            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { throw BridgeServerError.connectionClosed }
            buffer.append(chunk)

            if let request = HTTPRequest.parse(from: buffer) {
                return request
            }
        }

        throw BridgeServerError.malformedRequest
    }

    private func receiveChunk(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) async throws {
        try await sendRaw(response.serialize(), on: connection)
    }

    private func sendRaw(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Authentication

    private func authenticate(_ request: HTTPRequest) -> Bool {
        guard let value = request.header("Authorization") else { return false }
        return value == "Bearer \(authToken)"
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        // POST /containers
        if request.method == "POST" && request.path == "/containers" {
            return await handleCreateContainer(request)
        }

        // Container-scoped routes: /containers/{id}[/action]
        if let (id, action) = parseContainerRoute(request.path) {
            switch (request.method, action) {
            case ("GET", "status"):
                return await handleGetStatus(id: id)
            case ("GET", "output"):
                return await handleGetOutput(id: id)
            case ("DELETE", nil):
                return await handleDelete(id: id)
            default:
                break
            }
        }

        return .notFound
    }

    /// Parses paths like `/containers/{id}` or `/containers/{id}/action`.
    private func parseContainerRoute(_ path: String) -> (id: String, action: String?)? {
        let prefix = "/containers/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        guard !rest.isEmpty else { return nil }
        let parts = rest.split(separator: "/", maxSplits: 1)
        let id = String(parts[0])
        let action = parts.count > 1 ? String(parts[1]) : nil
        return (id, action)
    }

    // MARK: - POST /containers

    private func handleCreateContainer(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = try? JSONDecoder().decode(CreateContainerRequest.self, from: request.body) else {
            return .badRequest
        }

        do {
            let id = try await containerEngine.createTaskContainer(
                image: body.image,
                env: body.env,
                files: body.files
            )
            return .json(CreateContainerResponse(id: id), status: 201, statusText: "Created")
        } catch {
            debugLog("[BridgeServer] POST /containers failed: \(error)")
            return .error(500, "Internal Server Error",
                          message: "Failed to create container: \(error)")
        }
    }

    // MARK: - GET /containers/{id}/status

    private func handleGetStatus(id: String) async -> HTTPResponse {
        do {
            let (status, exitCode) = try await containerEngine.containerStatus(id)
            let logs = try? await containerEngine.readContainerLogs(id)
            return .json(ContainerStatusResponse(id: id, status: status, exitCode: exitCode, logs: logs))
        } catch {
            return .error(404, "Not Found", message: "Container not found: \(id)")
        }
    }

    // MARK: - GET /containers/{id}/logs (SSE)

    private func streamLogs(id: String, on connection: NWConnection) async {
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "\r\n"

        do {
            try await sendRaw(Data(header.utf8), on: connection)
            let stream = try await containerEngine.containerLogs(id)
            for try await line in stream {
                try await sendRaw(Data("data: \(line)\n\n".utf8), on: connection)
            }
        } catch {
            // Stream ended or connection closed — close gracefully
        }

        connection.cancel()
    }

    // MARK: - GET /containers/{id}/output

    private func handleGetOutput(id: String) async -> HTTPResponse {
        do {
            let output = try await containerEngine.readContainerOutput(id)
            return .json(ContainerOutputResponse(output: output))
        } catch {
            return .error(404, "Not Found",
                          message: "Output not available for container: \(id)")
        }
    }

    // MARK: - DELETE /containers/{id}

    private func handleDelete(id: String) async -> HTTPResponse {
        do {
            try await containerEngine.stopAndRemoveContainer(id)
            return .noContent
        } catch {
            return .error(500, "Internal Server Error",
                          message: "Failed to remove container: \(error)")
        }
    }

    // MARK: - GET /litellm-login (unauthenticated)

    /// Returns an HTML page that POSTs to LiteLLM's /v2/login via fetch(), setting
    /// the auth cookie on localhost, then redirects to the LiteLLM UI.
    /// Served from localhost:9876 so the cookie domain matches localhost:4000.
    private func handleLiteLLMLogin() -> HTTPResponse {
        guard let masterKey = try? KeychainManager.getOrCreateLiteLLMKey() else {
            return .error(500, "Internal Server Error", message: "Unable to read LiteLLM key")
        }

        let html = """
        <!DOCTYPE html><html><body><p>Logging in&hellip;</p><script>
        fetch("http://localhost:4000/v2/login",{
          method:"POST",
          headers:{"Content-Type":"application/json"},
          credentials:"include",
          body:JSON.stringify({username:"admin",password:"\(masterKey)"})
        }).then(r=>r.json()).then(d=>{
          window.location.href=d.redirect_url||"http://localhost:4000/ui/";
        }).catch(()=>{window.location.href="http://localhost:4000/ui/";});
        </script></body></html>
        """

        return .html(html)
    }
}

enum BridgeServerError: Error, LocalizedError {
    case invalidPort
    case connectionClosed
    case malformedRequest

    var errorDescription: String? {
        switch self {
        case .invalidPort: "Invalid port number"
        case .connectionClosed: "Connection closed"
        case .malformedRequest: "Malformed HTTP request"
        }
    }
}
