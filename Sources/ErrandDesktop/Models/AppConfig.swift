import Foundation

/// Persisted application configuration stored at
/// ~/Library/Application Support/ErrandDesktop/config.json
struct AppConfig: Codable, Sendable {
    var openaiBaseURL: String = ""
    var openaiAPIKey: String = ""
    var backendPort: Int = 8000
    var postgresPort: Int = 5432
    var valkeyPort: Int = 6379
    var litellmPort: Int = 4000
    var hindsightPort: Int = 9999
    var hindsightLLMModel: String = ""
    var hindsightEmbeddingModel: String = ""
    var useLiteLLM: Bool = true
    var useHindsight: Bool = true
    var containerRuntime: String = "docker"
    var launchAtLogin: Bool = false
    var contentManagerImageTag: String = "latest"
    var showBetaVersions: Bool = false
}
