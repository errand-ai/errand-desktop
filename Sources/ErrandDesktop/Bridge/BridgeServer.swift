@preconcurrency import Network
import Foundation
import Security


/// Local HTTP server exposing the container bridge API for the worker.
///
/// The socket binds to all interfaces (so worker containers on the vmnet
/// subnet can reach it), but every connection's source address is validated:
/// only loopback and hosts on the vmnet gateway's subnet are served, falling
/// back to the RFC 1918 private ranges when the runtime exposes no numeric
/// gateway (Docker). All API
/// routes require a bearer token; the browser-facing `/litellm-login` page
/// instead requires a short-lived one-time token.
actor BridgeServer {
    private let containerEngine: ContainerEngine
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sh.errand.bridge-server")

    /// The port the listener was started on (used to build login URLs).
    private var boundPort: UInt16 = 9876

    /// The vmnet gateway address, if known. Connections are accepted from
    /// loopback and from any peer on this address's /24 subnet (containers
    /// connect from their own subnet-peer IPs, not the gateway itself).
    /// Nil when the runtime does not expose a numeric gateway (e.g. Docker),
    /// in which case peers are validated against the RFC 1918 private ranges.
    private var allowedGatewayIPv4: IPv4Address?

    /// Active one-time login tokens mapped to their creation time.
    /// Consumed on first use and expired after 60 seconds.
    private var loginTokens: [String: Date] = [:]
    private let loginTokenLifetime: TimeInterval = 60

    /// Bearer token for authenticating API requests.
    /// Generated at init; pass to worker container as CONTAINER_BRIDGE_TOKEN.
    let authToken: String

    init(containerEngine: ContainerEngine) {
        self.containerEngine = containerEngine
        self.authToken = UUID().uuidString
    }

    /// Start the HTTP server on the given port.
    ///
    /// The socket binds to all interfaces so containers on the vmnet subnet can
    /// reach it, but `accept(_:)` rejects any peer that is not loopback or on the
    /// `allowedGatewayIP` subnet. Pass the vmnet gateway IP so worker containers
    /// are permitted; pass a non-numeric value (Docker, whose gateway is the name
    /// `host.docker.internal`) to fall back to the RFC 1918 private ranges.
    func start(port: UInt16 = 9876, allowedGatewayIP: String? = nil) throws {
        let params = NWParameters.tcp

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw BridgeServerError.invalidPort
        }

        self.boundPort = port
        self.allowedGatewayIPv4 = allowedGatewayIP.flatMap { IPv4Address($0) }
        if allowedGatewayIP != nil && self.allowedGatewayIPv4 == nil {
            print("[BridgeServer] Gateway '\(allowedGatewayIP!)' is not a numeric IPv4 — falling back to RFC 1918 ranges")
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
        // Reject connections from hosts that are neither loopback nor on the
        // vmnet gateway subnet, without reading any request data.
        guard isAllowedPeer(connection) else {
            debugLog("[BridgeServer] Rejected connection from non-local peer \(remoteIP(of: connection) ?? "unknown")")
            connection.cancel()
            return
        }

        connection.start(queue: queue)

        do {
            let request = try await receiveRequest(from: connection)

            // Browser-facing auto-login page for the LiteLLM UI. Requires a valid
            // one-time token (browsers cannot set the Authorization header).
            if request.method == "GET" && request.path == "/litellm-login" {
                let response = handleLiteLLMLogin(request)
                try await send(response, on: connection)
                connection.cancel()
                return
            }

            guard authenticate(request) else {
                try await send(.unauthorized, on: connection)
                connection.cancel()
                return
            }

            // Authenticated: mints a one-time login URL for the LiteLLM UI.
            if request.method == "GET" && request.path == "/litellm-login-url" {
                let response = handleLiteLLMLoginURL()
                try await send(response, on: connection)
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
        } catch is HTTPParseError {
            // Currently only bodyTooLarge.
            try? await send(
                .error(413, "Request Entity Too Large",
                       message: "Request body exceeds \(maxBodyBytes) bytes"),
                on: connection
            )
        } catch {
            debugLog("[BridgeServer] Request error: \(error)")
            try? await send(
                .error(500, "Internal Server Error", message: "\(error)"),
                on: connection
            )
        }

        connection.cancel()
    }

    // MARK: - Source-Address Validation

    /// Returns true if the connection's peer is loopback, on the vmnet gateway's
    /// /24 subnet, or — when no numeric gateway is known — in an RFC 1918 range.
    private func isAllowedPeer(_ connection: NWConnection) -> Bool {
        guard let host = remoteHost(of: connection) else {
            // Peer address is unavailable, so there is nothing to validate. Fail
            // open only when we also have no gateway (Docker), where rejecting
            // would break worker traffic; otherwise reject.
            return allowedGatewayIPv4 == nil
        }

        switch host {
        case .ipv4(let addr):
            return isAllowedIPv4Bytes(Array(addr.rawValue))
        case .ipv6(let addr):
            let bytes = Array(addr.rawValue)
            if addr == IPv6Address("::1") { return true }
            // IPv4-mapped IPv6 (::ffff:a.b.c.d): validate the embedded IPv4.
            if bytes.count == 16, bytes[10] == 0xff, bytes[11] == 0xff {
                return isAllowedIPv4Bytes(Array(bytes[12...15]))
            }
            return false
        default:
            // Hostname endpoints (`.name`) never appear for accepted TCP peers.
            return false
        }
    }

    /// Validates a 4-byte IPv4 address against loopback (127/8) and the gateway /24,
    /// falling back to the RFC 1918 ranges when no numeric gateway is known.
    private func isAllowedIPv4Bytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        if bytes[0] == 127 { return true } // loopback 127.0.0.0/8
        guard let gateway = allowedGatewayIPv4 else { return isPrivateIPv4(bytes) }
        let gw = Array(gateway.rawValue)
        return bytes[0] == gw[0] && bytes[1] == gw[1] && bytes[2] == gw[2]
    }

    /// True for the RFC 1918 private ranges: 10/8, 172.16/12, 192.168/16.
    ///
    /// Used only when the runtime exposes no numeric gateway (Docker), where the
    /// container subnet is private but not known ahead of time. This blocks peers
    /// reaching us over a public/routable address; it does not isolate us from
    /// other hosts on the same private LAN, which remains the reason every API
    /// route also requires the bearer token.
    private func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        switch (bytes[0], bytes[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }

    /// Extracts the remote peer's host from an inbound connection.
    private func remoteHost(of connection: NWConnection) -> NWEndpoint.Host? {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        if case let .hostPort(host, _) = endpoint {
            return host
        }
        return nil
    }

    /// Human-readable remote IP for logging, or nil if unavailable.
    private func remoteIP(of connection: NWConnection) -> String? {
        guard let host = remoteHost(of: connection) else { return nil }
        switch host {
        case .ipv4(let addr): return addr.debugDescription
        case .ipv6(let addr): return addr.debugDescription
        default: return nil
        }
    }

    // MARK: - HTTP I/O

    private func receiveRequest(from connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()

        for _ in 0..<10 {
            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { throw BridgeServerError.connectionClosed }
            buffer.append(chunk)

            if let request = try HTTPRequest.parse(from: buffer) {
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
        } else if request.path.hasPrefix("/containers/") {
            // A container-scoped path whose ID failed validation (e.g. path traversal).
            return .error(400, "Bad Request", message: "Invalid container ID")
        }

        return .notFound
    }

    /// Parses paths like `/containers/{id}` or `/containers/{id}/action`.
    /// Returns nil if the ID does not match `^[a-zA-Z0-9_-]{1,128}$`, which
    /// blocks path-traversal and other unexpected characters.
    private func parseContainerRoute(_ path: String) -> (id: String, action: String?)? {
        let prefix = "/containers/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        guard !rest.isEmpty else { return nil }
        let parts = rest.split(separator: "/", maxSplits: 1)
        let id = String(parts[0])
        guard isValidContainerID(id) else { return nil }
        let action = parts.count > 1 ? String(parts[1]) : nil
        return (id, action)
    }

    /// Validates a container ID against `^[a-zA-Z0-9_-]{1,128}$`.
    private func isValidContainerID(_ id: String) -> Bool {
        guard (1...128).contains(id.count) else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
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

    // MARK: - LiteLLM Auto-Login (one-time token)

    /// Mints a fresh one-time login URL for the LiteLLM UI. Called in-process by
    /// the app UI, which cannot attach a bearer token to the system browser.
    func makeLiteLLMLoginURL() -> URL? {
        URL(string: mintLoginURL())
    }

    /// Generates a one-time token, records it, and returns the `/litellm-login` URL.
    private func mintLoginURL() -> String {
        let otp = generateOTP()
        loginTokens[otp] = Date()
        return "http://localhost:\(boundPort)/litellm-login?token=\(otp)"
    }

    /// Validates and consumes a one-time login token. Tokens are single-use and
    /// expire after `loginTokenLifetime` seconds.
    private func consumeLoginToken(_ token: String?) -> Bool {
        // Opportunistically drop expired tokens.
        let now = Date()
        loginTokens = loginTokens.filter { now.timeIntervalSince($0.value) <= loginTokenLifetime }

        guard let token, let created = loginTokens.removeValue(forKey: token) else {
            return false
        }
        return now.timeIntervalSince(created) <= loginTokenLifetime
    }

    /// Generates a cryptographically random 64-character hex token.
    private func generateOTP() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fall back to UUIDs (still unpredictable) rather than a fixed value.
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - GET /litellm-login-url (authenticated)

    /// Returns a JSON body `{"url": "http://localhost:<port>/litellm-login?token=<otp>"}`.
    private func handleLiteLLMLoginURL() -> HTTPResponse {
        .json(["url": mintLoginURL()])
    }

    // MARK: - GET /litellm-login?token=<otp>

    /// Returns an HTML page that POSTs to LiteLLM's /v2/login via fetch(), setting
    /// the auth cookie on localhost, then redirects to the LiteLLM UI.
    /// Served from localhost:9876 so the cookie domain matches localhost:4000.
    /// Requires a valid one-time token, which is consumed on use.
    private func handleLiteLLMLogin(_ request: HTTPRequest) -> HTTPResponse {
        guard consumeLoginToken(request.queryValue("token")) else {
            return .unauthorized
        }
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
