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

/// Manages the optional LiteLLM proxy container.
/// Handles config.yaml generation, container lifecycle, and provides the proxy URL.
actor LiteLLMManager {
    private let containerEngine: ContainerEngine
    private let configDirectory: URL
    private let configFileURL: URL

    static let imageName = "ghcr.io/berriai/litellm:latest"
    static let defaultPort = 4000

    private(set) var providers: [LiteLLMProvider] = []
    private(set) var containerIP: String?
    private(set) var isRunning = false

    init(containerEngine: ContainerEngine) {
        self.containerEngine = containerEngine

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

    // MARK: - Container Lifecycle

    /// Pulls the LiteLLM container image.
    func pullImage() async throws {
        try await containerEngine.pullImage(name: Self.imageName)
    }

    /// Starts the LiteLLM proxy container with the generated config.yaml mounted.
    func start(port: Int = defaultPort) async throws {
        guard !isRunning else { return }

        // Ensure config.yaml exists
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            try generateConfigYAML()
        }

        let env: [String: String] = [:]
        let mounts: [String: String] = [
            configFileURL.path: "/app/config.yaml",
        ]

        let (containerId, ip) = try await containerEngine.createAndStartContainer(
            image: Self.imageName,
            env: env,
            mounts: mounts,
            ports: [port: 4000]
        )

        containerIP = ip
        isRunning = true
        _ = containerId // Stored by ContainerEngine in ServiceInfo
    }

    /// Stops the LiteLLM container.
    func stop() async throws {
        guard isRunning else { return }
        try await containerEngine.stopContainer(serviceId: "litellm")
        containerIP = nil
        isRunning = false
    }

    // MARK: - Proxy URL

    /// Returns the LiteLLM proxy base URL, or nil if not running.
    func proxyBaseURL(port: Int = defaultPort) -> String? {
        guard isRunning, let ip = containerIP else { return nil }
        return "http://\(ip):\(port)"
    }

    /// Resolves the effective OPENAI_BASE_URL.
    /// When LiteLLM is enabled and running, routes through the proxy.
    /// Otherwise falls back to the direct URL from config.
    func resolveOpenAIBaseURL(config: AppConfig) -> String {
        if config.litellmEnabled, let proxy = proxyBaseURL(port: config.litellmPort) {
            return proxy
        }
        return config.openaiBaseURL
    }
}
