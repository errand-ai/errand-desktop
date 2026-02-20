import Foundation

/// Persisted application configuration stored at
/// ~/Library/Application Support/ErrandDesktop/config.json
struct AppConfig: Codable, Sendable {
    var openaiBaseURL: String = ""
    var openaiAPIKey: String = ""
    var litellmEnabled: Bool = false
    var oidcDiscoveryURL: String = ""
    var oidcClientID: String = ""
    var oidcClientSecret: String = ""
    var backendPort: Int = 8000
    var postgresPort: Int = 5432
    var valkeyPort: Int = 6379
    var litellmPort: Int = 4000
    var launchAtLogin: Bool = false
    var contentManagerImageTag: String = "latest"
}
