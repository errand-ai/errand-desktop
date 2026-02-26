import Foundation

/// Request to create a task-runner container via the bridge API.
struct CreateContainerRequest: Codable, Sendable {
    let image: String
    let env: [String: String]
    let files: [String: String]
}

/// Response from creating a container.
struct CreateContainerResponse: Codable, Sendable {
    let id: String
}

/// Container status response from the bridge API.
struct ContainerStatusResponse: Codable, Sendable {
    let id: String
    let status: String  // "running", "exited"
    let exitCode: Int?
    let logs: String?
}

/// Container output response (result.json contents).
struct ContainerOutputResponse: Codable, Sendable {
    let output: String  // Raw JSON string of /output/result.json
}
