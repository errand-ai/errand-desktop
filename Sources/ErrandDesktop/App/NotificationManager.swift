import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Posts macOS user notifications for container lifecycle events and errors.
/// When running as a proper app bundle, uses UNUserNotificationCenter.
/// Falls back to osascript for dev builds without a bundle identifier.
enum NotificationManager {

    /// Whether the app is running as a proper bundle with an identifier.
    /// UNUserNotificationCenter fatally asserts when called without one.
    private static let hasBundleIdentifier: Bool = {
        // Check both main bundle and that Info.plist actually exists on disk,
        // because responsibleProcess inheritance can give a misleading bundleIdentifier.
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return Bundle.main.infoDictionary != nil
    }()

    /// Path to a temporary copy of the app logo for notification attachments.
    private static let logoURL: URL? = {
        guard let resource = Bundle.module.url(forResource: "errand-logo", withExtension: "png") else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("errand-notification-logo.png")
        try? FileManager.default.copyItem(at: resource, to: tmp)
        return tmp
    }()

    /// Requests notification authorization if not already granted.
    static func requestAuthorization() async {
        guard hasBundleIdentifier else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Notifies the user that a service container has started.
    static func postServiceStarted(_ displayName: String) async {
        await post(
            id: "service-started-\(displayName)",
            title: "\(displayName) Running",
            body: "\(displayName) container is now running."
        )
    }

    /// Notifies the user of a keychain access error.
    static func postKeychainError(_ message: String) async {
        await post(
            id: "keychain-error",
            title: "Keychain Error",
            body: message,
            sound: .defaultCritical
        )
    }

    /// Notifies the user of a service startup failure.
    static func postServiceError(_ displayName: String, error: String) async {
        await post(
            id: "service-error-\(displayName)",
            title: "\(displayName) Failed",
            body: error
        )
    }

    private static func post(
        id: String,
        title: String,
        body: String,
        sound: UNNotificationSound = .default
    ) async {
        if hasBundleIdentifier {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                debugLog("[Notification] Skipped (not authorized, status=\(settings.authorizationStatus.rawValue)): \(title)")
                return
            }
            debugLog("[Notification] Posting via UNUserNotificationCenter: \(title)")

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound
            if let logo = logoURL,
               let attachment = try? UNNotificationAttachment(identifier: "logo", url: logo, options: nil) {
                content.attachments = [attachment]
            }

            let request = UNNotificationRequest(
                identifier: id,
                content: content,
                trigger: nil
            )

            try? await center.add(request)
        } else {
            // Fallback for dev builds without a bundle identifier
            postViaOsascript(title: title, body: body)
        }
    }

    /// Posts a notification using osascript as a fallback when UNUserNotificationCenter
    /// is unavailable (no bundle identifier).
    private static func postViaOsascript(title: String, body: String) {
        let escaped = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(escaped(body))\" with title \"\(escaped(title))\""
        debugLog("[Notification] Posting via osascript: \(title)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
