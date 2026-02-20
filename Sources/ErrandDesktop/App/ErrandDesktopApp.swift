import SwiftUI

@main
struct ErrandDesktopApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.menuBarIconName)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        Window("Logs", id: "log-viewer") {
            LogViewerView()
                .environmentObject(appState)
        }

        Window("Setup", id: "first-run-setup") {
            SetupAssistantView()
                .environmentObject(appState)
        }
    }
}
