import Foundation

/// Status of an individual managed service.
enum ServiceStatus: String, Sendable {
    case stopped
    case pulling      // Downloading container image
    case starting     // Container created, waiting for healthy
    case running
    case stopping
    case error
}

/// Overall app status shown in the menu bar icon.
enum AppStatus: String, Sendable {
    case idle       // No services running
    case starting   // Services are starting up
    case running    // All services healthy
    case degraded   // Some services unhealthy
}

/// Represents a managed container service.
struct ServiceInfo: Identifiable, Sendable {
    let id: String          // e.g. "postgres", "valkey", "backend", "worker", "litellm", "migrate"
    let displayName: String // e.g. "PostgreSQL", "Valkey", "Backend", "Worker", "LiteLLM", "Migrate"
    var status: ServiceStatus = .stopped
    var port: Int?
    var containerId: String?
    var containerIP: String?
    var healthCheckFailures: Int = 0
    var isEphemeral: Bool = false
}

/// Startup order for services. Each group starts after the previous group is healthy.
let serviceStartupOrder: [[String]] = [
    ["postgres"],
    ["migrate", "valkey"],
    ["backend"],
    ["worker"],
]
