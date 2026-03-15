import Foundation

/// Detected LLM provider type based on HTTP endpoint probing.
enum ProviderType: String, Sendable {
    case litellm = "litellm"
    case openaiCompatible = "openai_compatible"
    case unknown = "unknown"
}

/// Probes an LLM provider URL to determine its type.
enum ProviderDetector {

    /// Probes the provider to determine its type.
    /// Tries LiteLLM detection first (`/model/info`), then OpenAI-compatible (`/models`), then falls back to unknown.
    static func detect(baseURL: String, apiKey: String) async -> ProviderType {
        // Try LiteLLM first: GET {base_url_without_v1}/model/info
        let strippedURL = baseURL.hasSuffix("/v1")
            ? String(baseURL.dropLast(3))
            : baseURL

        if await probeLiteLLM(baseURL: strippedURL, apiKey: apiKey) {
            return .litellm
        }

        // Try OpenAI-compatible: GET {base_url}/models
        if await probeOpenAICompatible(baseURL: baseURL, apiKey: apiKey) {
            return .openaiCompatible
        }

        return .unknown
    }

    private static func probeLiteLLM(baseURL: String, apiKey: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/model/info") else { return false }
        return await probeForDataArray(url: url, apiKey: apiKey)
    }

    private static func probeOpenAICompatible(baseURL: String, apiKey: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/models") else { return false }
        return await probeForDataArray(url: url, apiKey: apiKey)
    }

    private static func probeForDataArray(url: URL, apiKey: String) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["data"] is [Any]
        } catch {
            return false
        }
    }
}
