import Foundation

/// Status of an individual managed service.
enum ServiceStatus: String, Sendable {
    case stopped
    case pulling      // Downloading container image
    case preparing    // Extracting rootfs from image layers
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
    let id: String          // e.g. "postgres", "valkey", "backend", "litellm", "migrate", "playwright"
    let displayName: String // e.g. "PostgreSQL", "Valkey", "Backend", "LiteLLM", "Migrate", "Playwright"
    var status: ServiceStatus = .stopped
    var port: Int?          // localhost port for forwarding
    var containerPort: Int? // container-internal port, if different from `port`
    var containerId: String?
    var containerIP: String?
    var healthCheckFailures: Int = 0
    var isEphemeral: Bool = false
    var preparingProgress: Double?  // 0.0–1.0 during rootfs extraction
}

/// Dependency graph for service startup. Each key depends on the listed services being healthy first.
/// Services with no dependencies (empty array) start immediately and in parallel.
let serviceDependencies: [String: [String]] = [
    "postgres": [],
    "valkey": [],
    "gdrive-mcp": [],
    "onedrive-mcp": [],
    "playwright": [],
    "migrate": ["postgres"],
    "litellm": ["postgres"],
    "hindsight": ["postgres", "litellm"],
    "backend": ["migrate", "litellm"],
]

/// Computes a reverse-topological shutdown order from the dependency graph.
/// Services that depend on others are stopped first.
func serviceShutdownOrder() -> [[String]] {
    // Topological sort into levels by depth
    var depths: [String: Int] = [:]

    func depth(of id: String) -> Int {
        if let cached = depths[id] { return cached }
        let deps = serviceDependencies[id] ?? []
        let d = deps.isEmpty ? 0 : (deps.map { depth(of: $0) }.max()! + 1)
        depths[id] = d
        return d
    }

    for id in serviceDependencies.keys { _ = depth(of: id) }

    // Group by depth, then reverse so deepest (most dependent) stops first
    let maxDepth = depths.values.max() ?? 0
    var groups: [[String]] = []
    for d in stride(from: maxDepth, through: 0, by: -1) {
        let group = depths.filter { $0.value == d }.map(\.key)
        if !group.isEmpty { groups.append(group) }
    }
    return groups
}
