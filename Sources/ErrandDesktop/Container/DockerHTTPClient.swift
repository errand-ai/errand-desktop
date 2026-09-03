import Foundation
import Synchronization
@preconcurrency import Network

/// Thin HTTP client that communicates with the Docker Engine API over a Unix domain socket.
/// Uses NWConnection for the transport layer and hand-rolls minimal HTTP/1.1 request/response parsing.
actor DockerHTTPClient {

    private let socketPath: String

    init(socketPath: String = "/var/run/docker.sock") {
        self.socketPath = socketPath
    }

    // MARK: - Public API

    /// Sends an HTTP request and returns the full response body and status code.
    func request(
        method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, Int) {
        let connection = try createConnection()
        defer { connection.cancel() }

        try await connect(connection)
        let requestData = buildHTTPRequest(method: method, path: path, body: body, headers: headers)
        try await send(connection, data: requestData)
        return try await receiveFullResponse(connection)
    }

    /// Sends an HTTP request and streams the response body line by line.
    /// Useful for `POST /images/create` (pull with progress) and `GET /containers/{id}/logs`.
    func requestStreaming(
        method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let connection = try self.createConnection()
                    try await self.connect(connection)
                    // Don't send Connection: close for streaming — Docker may abort long-running
                    // responses (like image pulls) if the client signals connection close intent.
                    let requestData = self.buildHTTPRequest(method: method, path: path, body: body, headers: headers, connectionClose: false)
                    try await self.send(connection, data: requestData)

                    debugLog("[DockerHTTPClient] Streaming \(method) \(path)")

                    // Read the HTTP response header first
                    let headerData = try await self.receiveUntilHeaderEnd(connection)
                    guard let headerString = String(data: headerData, encoding: .utf8) else {
                        throw DockerError.invalidResponse
                    }

                    // Log status for debugging
                    debugLog("[DockerHTTPClient] Streaming response: \(headerString.split(separator: "\r\n").first ?? "?")")

                    // Check HTTP status code — non-2xx means failure
                    let statusCode = self.parseStatusCode(from: headerString)

                    // Find the header/body boundary in the raw bytes (NOT the String,
                    // because Swift counts \r\n as a single Character but it's 2 bytes).
                    let headerSep = Data("\r\n\r\n".utf8)
                    guard let sepRange = headerData.range(of: headerSep) else {
                        throw DockerError.invalidResponse
                    }
                    let leftover = Data(headerData[sepRange.upperBound...])

                    if statusCode < 200 || statusCode >= 300 {
                        let errorBody = String(data: leftover, encoding: .utf8) ?? ""
                        throw DockerError.apiError(statusCode, errorBody)
                    }

                    // Check if response uses chunked transfer encoding
                    let isChunked = headerString.lowercased().contains("transfer-encoding: chunked")


                    if isChunked {
                        var buffer = leftover
                        try await self.readChunkedStream(connection, leftover: &buffer, continuation: continuation)
                    } else {
                        // Non-chunked: yield data as it arrives for true streaming
                        var totalBytes = 0
                        let contentLength = self.parseContentLength(from: headerString)

                        if !leftover.isEmpty {
                            continuation.yield(leftover)
                            totalBytes += leftover.count
                        }

                        if let contentLength {
                            while totalBytes < contentLength {
                                let chunk = try await self.receive(connection)
                                if chunk.isEmpty { break }
                                continuation.yield(chunk)
                                totalBytes += chunk.count
                            }
                        } else {
                            // No content-length — read until connection closes
                            while true {
                                do {
                                    let chunk = try await self.receive(connection)
                                    if chunk.isEmpty { break }
                                    continuation.yield(chunk)
                                    totalBytes += chunk.count
                                } catch {
                                    break
                                }
                            }
                        }

                        debugLog("[DockerHTTPClient] Non-chunked stream done, total=\(totalBytes) bytes")
                    }

                    connection.cancel()
                    continuation.finish()
                } catch {
                    debugLog("[DockerHTTPClient] Streaming error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Connection

    private nonisolated func createConnection() throws -> NWConnection {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters.tcp
        return NWConnection(to: endpoint, using: params)
    }

    private nonisolated func connect(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // `stateUpdateHandler` may fire concurrently from Network's queue with
            // multiple states; a Mutex-guarded flag ensures the continuation is
            // resumed exactly once. Returns true only for the caller that wins.
            let resumed = Mutex(false)
            @Sendable func claimResume() -> Bool {
                resumed.withLock { done in
                    guard !done else { return false }
                    done = true
                    return true
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if claimResume() { continuation.resume() }
                case .failed(let error):
                    if claimResume() { continuation.resume(throwing: error) }
                case .cancelled:
                    if claimResume() { continuation.resume(throwing: DockerError.connectionCancelled) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "docker-http-\(UUID().uuidString.prefix(8))"))
        }
    }

    // MARK: - Send / Receive

    private nonisolated func send(_ connection: NWConnection, data: Data) async throws {
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

    private nonisolated func receive(_ connection: NWConnection, minLength: Int = 1, maxLength: Int = 65536) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minLength, maximumLength: maxLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    // No data, not complete, no error — treat as closed
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - HTTP Parsing

    private nonisolated func buildHTTPRequest(method: String, path: String, body: Data?, headers: [String: String], connectionClose: Bool = true) -> Data {
        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: localhost\r\n"

        if let body {
            request += "Content-Length: \(body.count)\r\n"
            if headers["Content-Type"] == nil {
                request += "Content-Type: application/json\r\n"
            }
        }

        for (key, value) in headers {
            request += "\(key): \(value)\r\n"
        }

        if connectionClose {
            request += "Connection: close\r\n"
        }
        request += "\r\n"

        var data = request.data(using: .utf8)!
        if let body { data.append(body) }
        return data
    }

    private nonisolated func receiveUntilHeaderEnd(_ connection: NWConnection) async throws -> Data {
        var accumulated = Data()
        let headerSeparator = Data("\r\n\r\n".utf8)

        while true {
            let chunk = try await receive(connection)
            if chunk.isEmpty {
                throw DockerError.connectionClosed
            }
            accumulated.append(chunk)
            if accumulated.range(of: headerSeparator) != nil {
                return accumulated
            }
        }
    }

    private nonisolated func receiveFullResponse(_ connection: NWConnection) async throws -> (Data, Int) {
        let headerData = try await receiveUntilHeaderEnd(connection)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw DockerError.invalidResponse
        }

        let statusCode = parseStatusCode(from: headerString)
        let isChunked = headerString.lowercased().contains("transfer-encoding: chunked")
        let contentLength = parseContentLength(from: headerString)

        // Find header/body boundary in raw bytes (not String, where \r\n is 1 Character but 2 bytes)
        let headerSep = Data("\r\n\r\n".utf8)
        guard let sepRange = headerData.range(of: headerSep) else {
            throw DockerError.invalidResponse
        }
        var body = Data(headerData[sepRange.upperBound...])

        if isChunked {
            body = try await readAllChunkedData(connection, initialData: body)
        } else if let contentLength {
            while body.count < contentLength {
                let chunk = try await receive(connection)
                if chunk.isEmpty { break }
                body.append(chunk)
            }
        } else {
            // No content-length, no chunked — read until connection closes
            while true {
                do {
                    let chunk = try await receive(connection)
                    if chunk.isEmpty { break }
                    body.append(chunk)
                } catch {
                    break
                }
            }
        }

        return (body, statusCode)
    }

    private nonisolated func parseStatusCode(from header: String) -> Int {
        // "HTTP/1.1 200 OK" → 200
        let parts = header.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]) else { return 0 }
        return code
    }

    private nonisolated func parseContentLength(from header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    // MARK: - Chunked Transfer Encoding

    private nonisolated func readAllChunkedData(_ connection: NWConnection, initialData: Data) async throws -> Data {
        var result = Data()
        var buffer = initialData

        while true {
            // Find chunk size line
            let crlf = Data("\r\n".utf8)
            while buffer.range(of: crlf) == nil {
                let chunk = try await receive(connection)
                if chunk.isEmpty { return result }
                buffer.append(chunk)
            }

            guard let crlfRange = buffer.range(of: crlf) else { return result }
            let sizeString = String(data: buffer[buffer.startIndex..<crlfRange.lowerBound], encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
            buffer = Data(buffer[crlfRange.upperBound...])

            // Parse chunk size (hex)
            guard let chunkSize = Int(sizeString, radix: 16) else { return result }
            if chunkSize == 0 { return result } // Final chunk

            // Read chunk data + trailing CRLF
            let needed = chunkSize + 2 // +2 for trailing \r\n
            while buffer.count < needed {
                let chunk = try await receive(connection)
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }

            result.append(buffer.prefix(chunkSize))
            buffer = Data(buffer.dropFirst(min(needed, buffer.count)))
        }
    }

    private nonisolated func readChunkedStream(
        _ connection: NWConnection,
        leftover: inout Data,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        var buffer = leftover
        var chunkCount = 0
        var totalBytes = 0

        while true {
            let crlf = Data("\r\n".utf8)
            while buffer.range(of: crlf) == nil {
                let chunk = try await receive(connection)
                if chunk.isEmpty {
                    debugLog("[DockerHTTPClient] Chunked stream: connection closed after \(chunkCount) chunks, \(totalBytes) bytes")
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
            }

            guard let crlfRange = buffer.range(of: crlf) else {
                debugLog("[DockerHTTPClient] Chunked stream: no CRLF found, finishing")
                continuation.finish()
                return
            }
            let sizeString = String(data: buffer[buffer.startIndex..<crlfRange.lowerBound], encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? ""
            buffer = Data(buffer[crlfRange.upperBound...])

            // Skip empty lines between chunks (some servers send extra CRLFs)
            if sizeString.isEmpty {
                continue
            }

            // Strip chunk extensions (e.g. "1a;ext=val" → "1a")
            let sizeHex = sizeString.split(separator: ";").first.map(String.init) ?? sizeString

            guard let chunkSize = Int(sizeHex, radix: 16) else {
                debugLog("[DockerHTTPClient] Chunked stream: invalid chunk size '\(sizeString)', finishing after \(chunkCount) chunks")
                continuation.finish()
                return
            }
            if chunkSize == 0 {
                debugLog("[DockerHTTPClient] Chunked stream: final chunk after \(chunkCount) chunks, \(totalBytes) bytes")
                continuation.finish()
                return
            }

            let needed = chunkSize + 2
            while buffer.count < needed {
                let chunk = try await receive(connection)
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }

            let chunkData = Data(buffer.prefix(chunkSize))
            continuation.yield(chunkData)
            chunkCount += 1
            totalBytes += chunkSize
            buffer = Data(buffer.dropFirst(min(needed, buffer.count)))
        }
    }
}

// MARK: - Errors

enum DockerError: Error, LocalizedError {
    case connectionCancelled
    case connectionClosed
    case invalidResponse
    case apiError(Int, String)
    case containerNotFound(String)
    case execFailed(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .connectionCancelled: return "Docker connection cancelled"
        case .connectionClosed: return "Docker connection closed unexpectedly"
        case .invalidResponse: return "Invalid response from Docker daemon"
        case .apiError(let code, let msg): return "Docker API error \(code): \(msg)"
        case .containerNotFound(let id): return "Docker container not found: \(id)"
        case .execFailed(let msg): return "Docker exec failed: \(msg)"
        case .networkError(let msg): return "Docker network error: \(msg)"
        }
    }
}
