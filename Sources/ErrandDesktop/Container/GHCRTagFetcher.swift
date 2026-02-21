import Foundation

/// Fetches OCI image tags from GitHub Container Registry using anonymous token exchange.
enum GHCRTagFetcher {

    /// Fetches all tags for a GHCR image, sorted newest-first by semver.
    /// - Parameters:
    ///   - image: The image path (e.g. "errand-ai/errand-backend")
    ///   - includeBeta: When true, include PR build tags (e.g. "0.50.0-pr55")
    /// - Returns: Sorted array of tag strings, newest first
    static func fetchTags(image: String, includeBeta: Bool = false) async throws -> [String] {
        // Step 1: Get anonymous bearer token
        let tokenURL = URL(string: "https://ghcr.io/token?scope=repository:\(image):pull&service=ghcr.io")!
        let (tokenData, _) = try await URLSession.shared.data(from: tokenURL)
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: tokenData)
        guard let token = tokenResponse.token else {
            throw FetchError.noToken
        }

        // Step 2: List tags
        var request = URLRequest(url: URL(string: "https://ghcr.io/v2/\(image)/tags/list")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (tagsData, _) = try await URLSession.shared.data(for: request)
        let tagsResponse = try JSONDecoder().decode(TagsResponse.self, from: tagsData)

        // Optionally filter out PR build tags (e.g. "0.50.0-pr55") and sort by descending semver
        let tags = tagsResponse.tags ?? []
        return tags
            .filter { includeBeta || !$0.contains("-pr") }
            .sorted { semverCompare($0, $1) }
    }

    /// Compares two semver-like strings in descending order.
    private static func semverCompare(_ a: String, _ b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        let bParts = b.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        for (av, bv) in zip(aParts, bParts) {
            if av != bv { return av > bv }
        }
        return aParts.count > bParts.count
    }

    // MARK: - Response Types

    private struct TokenResponse: Codable {
        let token: String?
    }

    private struct TagsResponse: Codable {
        let tags: [String]?
    }

    enum FetchError: Error, LocalizedError {
        case noToken

        var errorDescription: String? {
            switch self {
            case .noToken: "Failed to obtain GHCR anonymous token"
            }
        }
    }
}
