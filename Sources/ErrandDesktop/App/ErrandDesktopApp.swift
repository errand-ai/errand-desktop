import SwiftUI

@main
struct ErrandDesktopApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Start initialization at app launch so auto-start works without
        // waiting for the user to click the menu bar icon. The popover's
        // .task also calls initialize(), but the guard ensures it only runs once.
        let state = _appState.wrappedValue
        Task { @MainActor in
            await state.initialize()
        }
    }

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
