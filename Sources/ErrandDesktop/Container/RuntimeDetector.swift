import Foundation

/// Available container runtime backends.
enum RuntimeCapability: String, Codable, CaseIterable, Sendable {
    case docker = "docker"
    case appleContainerization = "apple"

    var displayName: String {
        switch self {
        case .docker: return "Docker"
        case .appleContainerization: return "Apple Containerization"
        }
    }

    var description: String {
        switch self {
        case .docker:
            return "Industry standard. Runs on macOS 13+ (Intel & Apple Silicon). Fast startup, no rootfs extraction."
        case .appleContainerization:
            return "Native macOS virtualization. Requires macOS 26+ and Apple Silicon. Lightweight VMs, no Docker dependency."
        }
    }
}

/// Detects which container runtimes are available on the current system.
struct RuntimeDetector: Sendable {

    /// Checks all runtimes and returns the available ones.
    static func detectAvailable() async -> [RuntimeCapability] {
        var available: [RuntimeCapability] = []

        if await isDockerAvailable() {
            available.append(.docker)
        }

        if isAppleContainerizationAvailable() {
            available.append(.appleContainerization)
        }

        return available
    }

    /// Returns the best default runtime from the available options.
    static func defaultRuntime(from available: [RuntimeCapability]) -> RuntimeCapability? {
        // Prefer Docker as the primary runtime
        if available.contains(.docker) { return .docker }
        if available.contains(.appleContainerization) { return .appleContainerization }
        return nil
    }

    /// Returns runtimes that could work on this hardware, regardless of whether
    /// the daemon is currently running. Docker is always installable on macOS;
    /// Apple Containerization requires macOS 26+ and Apple Silicon.
    static func detectInstallable() -> [RuntimeCapability] {
        var installable: [RuntimeCapability] = [.docker]  // Docker works on any Mac
        if isAppleContainerizationAvailable() {
            installable.append(.appleContainerization)
        }
        return installable
    }

    /// Apple Containerization requires macOS 26+ and ARM64 (Apple Silicon).
    static func isAppleContainerizationAvailable() -> Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else { return false }

        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Common Docker-compatible socket paths (Docker Desktop, Colima, OrbStack, Rancher Desktop).
    private static let knownSocketPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/var/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.colima/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.rd/docker.sock",
        ]
    }()

    /// Returns the path to a working Docker-compatible socket, or nil if none found.
    /// Checks `DOCKER_HOST` env var first, then known socket locations.
    static func findDockerSocket() async -> String? {
        // Check DOCKER_HOST environment variable first (e.g. "unix:///path/to/socket")
        if let dockerHost = ProcessInfo.processInfo.environment["DOCKER_HOST"] {
            let path = dockerHost.replacingOccurrences(of: "unix://", with: "")
            if FileManager.default.fileExists(atPath: path),
               await pingDocker(socketPath: path) {
                return path
            }
        }

        // Try known socket locations
        for path in knownSocketPaths {
            if FileManager.default.fileExists(atPath: path),
               await pingDocker(socketPath: path) {
                return path
            }
        }

        return nil
    }

    /// Docker is available if a working socket is found and the daemon responds to ping.
    static func isDockerAvailable() async -> Bool {
        await findDockerSocket() != nil
    }

    /// Pings the Docker daemon at the given socket path.
    private static func pingDocker(socketPath: String) async -> Bool {
        do {
            let client = DockerHTTPClient(socketPath: socketPath)
            let (_, statusCode) = try await client.request(method: "GET", path: "/_ping")
            return statusCode == 200
        } catch {
            return false
        }
    }
}
