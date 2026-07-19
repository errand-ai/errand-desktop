import Foundation

/// Abstraction layer for container lifecycle operations.
/// Both Docker and Apple Containerization implement this protocol,
/// allowing ContainerEngine to be runtime-agnostic.
protocol ContainerRuntime: Sendable {
    /// Pulls an image from a registry, optionally reporting download progress (0.0–1.0).
    func pullImage(reference: String, onProgress: (@Sendable (Double) -> Void)?) async throws

    /// Creates a container with the given ID and configuration.
    func createContainer(id: String, config: ContainerConfig) async throws

    /// Starts a previously created container.
    func startContainer(id: String) async throws

    /// Stops a running container, waiting up to `timeout` seconds for graceful shutdown.
    func stopContainer(id: String, timeout: Int) async throws

    /// Removes a stopped container and its resources.
    func removeContainer(id: String) async throws

    /// Executes a command inside a running container.
    func execInContainer(id: String, command: [String]) async throws -> ExecResult

    /// Returns the IP address of a container on the shared network, or nil if unavailable.
    func containerIP(id: String) async throws -> String?

    /// Returns an async stream of log lines from a container.
    func containerLogs(id: String) async throws -> AsyncStream<String>

    /// Cleans up all Errand-managed containers (prefixed with `errand-` and `task-`).
    func cleanup() async throws
}

/// Runtime-agnostic container configuration.
struct ContainerConfig: Sendable {
    /// OCI image reference (e.g. "docker.io/library/postgres:16").
    var image: String

    /// Environment variables to inject.
    var env: [String: String] = [:]

    /// Port mappings: host port → container port.
    var ports: [Int: Int] = [:]

    /// Volume mounts: host path → container path.
    var volumes: [String: String] = [:]

    /// Command override (nil = use image default CMD).
    var command: [String]?

    /// Entrypoint override (nil = use image default ENTRYPOINT). Docker runtime only.
    var entrypoint: [String]?

    /// Shared memory size in bytes (nil = Docker default 64MB). Docker runtime only.
    var shmSize: Int64?

    /// Docker network name to attach to (Docker runtime only).
    var network: String?

    /// Callback for container log lines.
    var onLog: (@Sendable (String) -> Void)?

    /// Callback for rootfs extraction / pull progress (0.0–1.0).
    var onProgress: (@Sendable (Double) -> Void)?

    /// CPU count for the container (Apple Containerization only).
    var cpus: Int = 2

    /// Memory limit in bytes (Apple Containerization only).
    var memoryInBytes: UInt64 = 1024 * 1024 * 1024

    /// Rootfs size in bytes for sparse image (Apple Containerization only).
    var rootfsSizeInBytes: UInt64 = 4 * 1024 * 1024 * 1024

    /// Estimated content size for progress calculation (Apple Containerization only).
    var estimatedContentBytes: UInt64 = 500_000_000
}

/// Result of executing a command inside a container.
struct ExecResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
