import Foundation

/// A single LiteLLM model provider configuration entry.
struct LiteLLMProvider: Codable, Identifiable, Sendable {
    var id = UUID()
    var providerName: String   // e.g. "openai", "anthropic", "ollama"
    var modelName: String      // e.g. "gpt-4", "claude-3-opus"
    var litellmModel: String   // e.g. "openai/gpt-4", "anthropic/claude-3-opus-20240229"
    var apiKey: String
    var baseURL: String        // Optional custom base URL

    enum CodingKeys: String, CodingKey {
        case id, providerName, modelName, litellmModel, apiKey, baseURL
    }
}

/// Manages LiteLLM proxy configuration.
/// Handles config.yaml generation and provider persistence.
actor LiteLLMManager {
    private let configDirectory: URL
    private let configFileURL: URL

    private(set) var providers: [LiteLLMProvider] = []

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.configDirectory = appSupport
            .appendingPathComponent("ErrandDesktop")
            .appendingPathComponent("data")
            .appendingPathComponent("litellm")
        self.configFileURL = configDirectory.appendingPathComponent("config.yaml")
    }

    // MARK: - Config Persistence

    /// Loads provider list from the persisted JSON sidecar file.
    func loadProviders() {
        let providersURL = configDirectory.appendingPathComponent("providers.json")
        guard let data = try? Data(contentsOf: providersURL) else { return }
        if let loaded = try? JSONDecoder().decode([LiteLLMProvider].self, from: data) {
            providers = loaded
        }
    }

    /// Saves the provider list and regenerates config.yaml.
    func saveProviders(_ newProviders: [LiteLLMProvider]) throws {
        providers = newProviders

        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        // Persist the provider list as JSON (for UI reload)
        let providersURL = configDirectory.appendingPathComponent("providers.json")
        let data = try JSONEncoder().encode(providers)
        try data.write(to: providersURL, options: .atomic)

        // Generate config.yaml for LiteLLM
        try generateConfigYAML()
    }

    /// Generates LiteLLM config.yaml from the current provider list.
    private func generateConfigYAML() throws {
        var yaml = "model_list:\n"
        for provider in providers {
            yaml += "  - model_name: \(provider.modelName)\n"
            yaml += "    litellm_params:\n"
            yaml += "      model: \(provider.litellmModel)\n"
            if !provider.apiKey.isEmpty {
                yaml += "      api_key: \(provider.apiKey)\n"
            }
            if !provider.baseURL.isEmpty {
                yaml += "      api_base: \(provider.baseURL)\n"
            }
        }

        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try yaml.write(to: configFileURL, atomically: true, encoding: .utf8)
    }

}
