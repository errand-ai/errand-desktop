import SwiftUI

@main
struct ErrandDesktopApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Trigger initialization immediately on app launch, not when the popover opens.
        let state = _appState.wrappedValue
        Task { @MainActor in
            await state.initialize()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(appState)
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
        .onChange(of: appState.isFirstRun) { _, isFirst in
            if isFirst {
                openWindow(id: "first-run-setup")
            }
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
