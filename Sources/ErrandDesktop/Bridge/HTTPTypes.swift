import Foundation

/// A parsed HTTP/1.1 request.
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [(String, String)]
    let body: Data

    /// Returns the value of the first header matching the given name (case-insensitive).
    func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.0.lowercased() == lowered }?.1
    }

    /// Attempts to parse an HTTP request from raw data.
    /// Returns nil if the data is incomplete (still waiting for headers or body).
    static func parse(from data: Data) -> HTTPRequest? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let sepRange = data.range(of: separator) else { return nil }

        let headerData = data[data.startIndex..<sepRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let fullPath = String(parts[1])
        // Strip query string for routing
        let path = fullPath.components(separatedBy: "?").first ?? fullPath

        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        let contentLength = headers
            .first { $0.0.lowercased() == "content-length" }
            .flatMap { Int($0.1) } ?? 0

        let bodyStart = sepRange.upperBound
        let availableBody = data.endIndex - bodyStart
        if availableBody < contentLength { return nil }

        let body: Data
        if contentLength > 0 {
            body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)])
        } else {
            body = Data()
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

/// An HTTP/1.1 response to send to the client.
struct HTTPResponse: Sendable {
    let statusCode: Int
    let statusText: String
    let headers: [(String, String)]
    let body: Data

    /// Serializes the response into raw HTTP bytes.
    func serialize() -> Data {
        var header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (name, value) in headers {
            header += "\(name): \(value)\r\n"
        }
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var result = Data(header.utf8)
        result.append(body)
        return result
    }

    /// Creates a JSON response from an Encodable value.
    static func json(_ value: some Encodable, status: Int = 200, statusText: String = "OK") -> HTTPResponse {
        let body = (try? JSONEncoder().encode(value)) ?? Data()
        return HTTPResponse(
            statusCode: status,
            statusText: statusText,
            headers: [("Content-Type", "application/json")],
            body: body
        )
    }

    /// Creates a JSON error response.
    static func error(_ statusCode: Int, _ statusText: String, message: String) -> HTTPResponse {
        json(["error": message], status: statusCode, statusText: statusText)
    }

    /// Creates an HTML response.
    static func html(_ body: String, status: Int = 200, statusText: String = "OK") -> HTTPResponse {
        HTTPResponse(
            statusCode: status,
            statusText: statusText,
            headers: [("Content-Type", "text/html; charset=utf-8")],
            body: Data(body.utf8)
        )
    }

    static let noContent = HTTPResponse(
        statusCode: 204, statusText: "No Content", headers: [], body: Data()
    )
    static let unauthorized = error(401, "Unauthorized", message: "Invalid or missing bearer token")
    static let notFound = error(404, "Not Found", message: "Not found")
    static let badRequest = error(400, "Bad Request", message: "Invalid request body")
}
