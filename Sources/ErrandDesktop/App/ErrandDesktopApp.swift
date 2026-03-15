import SwiftUI

@main
struct ErrandDesktopApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(appState)
                .task {
                    await appState.initialize()
                }
        } label: {
            if let url = Bundle.module.url(forResource: "menubar-icon", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: {
                    nsImage.size = NSSize(width: 18, height: 18)
                    nsImage.isTemplate = true
                    return nsImage
                }())
            } else {
                Image(systemName: appState.menuBarIconName)
            }
        }
        .menuBarExtraStyle(.window)

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
