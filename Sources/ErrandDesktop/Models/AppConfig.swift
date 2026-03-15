import Foundation

/// Persisted application configuration stored at
/// ~/Library/Application Support/ErrandDesktop/config.json
///
/// Uses a custom Decodable init so that adding new properties with defaults
/// doesn't break loading of older config.json files (missing keys get defaults).
struct AppConfig: Codable, Sendable {
    var deployLiteLLM: Bool = true
    var llmProviderName: String = ""
    var llmProviderBaseURL: String = ""
    var llmProviderAPIKey: String = ""
    var llmProviderType: String = ""
    var backendPort: Int = 8000
    var postgresPort: Int = 5432
    var valkeyPort: Int = 6379
    var litellmPort: Int = 4000
    var hindsightPort: Int = 9999
    var hindsightLLMModel: String = ""
    var hindsightEmbeddingModel: String = ""
    var useHindsight: Bool = true
    var useGoogleDrive: Bool = false
    var useOneDrive: Bool = false
    var containerRuntime: String = "docker"
    var autoStartContainers: Bool = true
    var launchAtLogin: Bool = false
    var contentManagerImageTag: String = "latest"
    var showBetaVersions: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        deployLiteLLM = (try? c.decode(Bool.self, forKey: .deployLiteLLM)) ?? defaults.deployLiteLLM
        llmProviderName = (try? c.decode(String.self, forKey: .llmProviderName)) ?? defaults.llmProviderName
        llmProviderBaseURL = (try? c.decode(String.self, forKey: .llmProviderBaseURL)) ?? defaults.llmProviderBaseURL
        llmProviderAPIKey = (try? c.decode(String.self, forKey: .llmProviderAPIKey)) ?? defaults.llmProviderAPIKey
        llmProviderType = (try? c.decode(String.self, forKey: .llmProviderType)) ?? defaults.llmProviderType
        backendPort = (try? c.decode(Int.self, forKey: .backendPort)) ?? defaults.backendPort
        postgresPort = (try? c.decode(Int.self, forKey: .postgresPort)) ?? defaults.postgresPort
        valkeyPort = (try? c.decode(Int.self, forKey: .valkeyPort)) ?? defaults.valkeyPort
        litellmPort = (try? c.decode(Int.self, forKey: .litellmPort)) ?? defaults.litellmPort
        hindsightPort = (try? c.decode(Int.self, forKey: .hindsightPort)) ?? defaults.hindsightPort
        hindsightLLMModel = (try? c.decode(String.self, forKey: .hindsightLLMModel)) ?? defaults.hindsightLLMModel
        hindsightEmbeddingModel = (try? c.decode(String.self, forKey: .hindsightEmbeddingModel)) ?? defaults.hindsightEmbeddingModel
        useHindsight = (try? c.decode(Bool.self, forKey: .useHindsight)) ?? defaults.useHindsight
        useGoogleDrive = (try? c.decode(Bool.self, forKey: .useGoogleDrive)) ?? defaults.useGoogleDrive
        useOneDrive = (try? c.decode(Bool.self, forKey: .useOneDrive)) ?? defaults.useOneDrive
        containerRuntime = (try? c.decode(String.self, forKey: .containerRuntime)) ?? defaults.containerRuntime
        autoStartContainers = (try? c.decode(Bool.self, forKey: .autoStartContainers)) ?? defaults.autoStartContainers
        launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        contentManagerImageTag = (try? c.decode(String.self, forKey: .contentManagerImageTag)) ?? defaults.contentManagerImageTag
        showBetaVersions = (try? c.decode(Bool.self, forKey: .showBetaVersions)) ?? defaults.showBetaVersions
    }
}
