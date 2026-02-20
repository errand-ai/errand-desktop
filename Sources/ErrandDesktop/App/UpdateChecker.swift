import Foundation
import UserNotifications

/// Checks GitHub Releases for available updates and notifies the user.
@MainActor
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var updateAvailable = false

    private var checkTask: Task<Void, Never>?

    /// The current app version from the bundle, or "0.0.0" during development.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Repository path for the GitHub Releases API.
    /// Update this to match your org/repo.
    static let repoPath = "errand/errand-desktop"

    /// Starts periodic update checks — on launch and every 24 hours.
    func startPeriodicChecks() {
        checkTask?.cancel()
        checkTask = Task {
            await checkForUpdate()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86400)) // 24 hours
                if Task.isCancelled { break }
                await checkForUpdate()
            }
        }
    }

    func stopPeriodicChecks() {
        checkTask?.cancel()
        checkTask = nil
    }

    /// Checks the GitHub Releases API for a newer version.
    func checkForUpdate() async {
        let urlString = "https://api.github.com/repos/\(Self.repoPath)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            latestVersion = remoteVersion
            downloadURL = release.htmlURL

            if isNewer(remote: remoteVersion, current: currentVersion) {
                updateAvailable = true
                await postUpdateNotification(version: remoteVersion, url: release.htmlURL)
            }
        } catch {
            // Silently fail — network may be unavailable
        }
    }

    /// Simple semver comparison (major.minor.patch).
    private func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    /// Posts a macOS notification about the available update.
    private func postUpdateNotification(version: String, url: String) async {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            // Request permission on first check
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "ErrandDesktop \(version) is available. Click to download."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "update-\(version)",
            content: content,
            trigger: nil // Deliver immediately
        )

        try? await center.add(request)
    }
}

/// Minimal GitHub Release response model.
private struct GitHubRelease: Codable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
