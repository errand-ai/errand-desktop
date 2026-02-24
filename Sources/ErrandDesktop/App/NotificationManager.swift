import Foundation
@preconcurrency import UserNotifications

/// Posts macOS user notifications for container lifecycle events and errors.
/// Guards against missing bundle identifiers (e.g. ad-hoc signed dev builds)
/// which cause UNUserNotificationCenter.current() to crash.
enum NotificationManager {

    /// Whether the app is running as a proper bundle with an identifier.
    /// UNUserNotificationCenter fatally asserts when called without one.
    private static let hasBundleIdentifier: Bool = {
        // Check both main bundle and that Info.plist actually exists on disk,
        // because responsibleProcess inheritance can give a misleading bundleIdentifier.
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return Bundle.main.infoDictionary != nil
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
        guard hasBundleIdentifier else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }
}
