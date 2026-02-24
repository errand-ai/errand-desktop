import SwiftUI

/// Main popover displayed when clicking the menu bar icon.
struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if appState.isFirstRun {
                firstRunPrompt
            } else {
                serviceList
                Divider()
                actionButtons
            }

            Divider()
            footerButtons
        }
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Text("Errand Desktop")
                .font(.headline)
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(appState.appStatus.color)
                    .frame(width: 8, height: 8)
                Text(appState.appStatus.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var firstRunPrompt: some View {
        VStack(spacing: 8) {
            Text("Setup Required")
                .font(.subheadline.weight(.medium))
            Text("Configure your API keys and pull container images to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Begin Setup...") {
                openWindow(id: "first-run-setup")
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var serviceList: some View {
        VStack(spacing: 2) {
            ForEach(appState.services) { service in
                HStack {
                    Circle()
                        .fill(service.status.color)
                        .frame(width: 8, height: 8)
                    Text(service.displayName)
                    Spacer()
                    if service.status == .preparing, let progress = service.preparingProgress {
                        Text("Preparing \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(service.status.color)
                            .monospacedDigit()
                    } else if service.status != .stopped && service.status != .running {
                        Text(service.status.label)
                            .font(.caption)
                            .foregroundStyle(service.status.color)
                    } else if let port = service.port {
                        Text(verbatim: "Port \(port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 6)
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button("Start All") {
                    appState.startAllInBackground()
                }
                .disabled(appState.appStatus != .idle)

                Button("Stop All") {
                    Task {
                        do {
                            try await appState.stopAll()
                        } catch {
                            appState.appendLog(service: "app", message: "Stop failed: \(error)")
                            print("[StopAll] Error: \(error)")
                        }
                    }
                }
                .disabled(appState.services.allSatisfy { $0.status == .stopped })
            }

            Button("Open in Browser") {
                appState.openInBrowser()
            }
            .disabled(appState.services.first { $0.id == "backend" }?.status != .running)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerButtons: some View {
        VStack(spacing: 0) {
            HStack {
                SettingsLink {
                    Text("Settings...")
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Logs...") {
                    openWindow(id: "log-viewer")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Button("Quit Errand Desktop") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Status Colors

extension ServiceStatus {
    var color: Color {
        switch self {
        case .running: .green
        case .pulling, .preparing: .blue
        case .starting, .stopping: .orange
        case .error: .red
        case .stopped: .gray
        }
    }

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .pulling: "Pulling..."
        case .preparing: "Preparing..."
        case .starting: "Starting..."
        case .running: "Running"
        case .stopping: "Stopping..."
        case .error: "Error"
        }
    }
}

extension AppStatus {
    var color: Color {
        switch self {
        case .running: .green
        case .starting: .orange
        case .degraded: .red
        case .idle: .gray
        }
    }
}
