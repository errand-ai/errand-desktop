import SwiftUI

/// Main popover displayed when clicking the menu bar icon.
struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let runtimeError = appState.runtimeError {
                runtimeErrorBanner(runtimeError)
            } else if let keychainError = appState.keychainError {
                keychainErrorBanner(keychainError)
            } else if appState.isFirstRun {
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

    private func runtimeErrorBanner(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox.slash")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("No Container Runtime")
                .font(.subheadline.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Download Docker") {
                if let url = URL(string: "https://www.docker.com/products/docker-desktop/") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Check Again") {
                Task {
                    await appState.detectAndSetRuntime()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private func keychainErrorBanner(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.lock.fill")
                .font(.title2)
                .foregroundStyle(.red)
            Text("Keychain Error")
                .font(.subheadline.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await appState.retryKeychainLoad()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
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

    /// URLs for services that have a web UI, keyed by service id.
    private func webUIURL(for serviceId: String) -> String? {
        switch serviceId {
        case "litellm": return "http://localhost:\(appState.config.litellmPort)/ui"
        case "hindsight": return "http://localhost:\(appState.config.hindsightPort)"
        case "backend": return "http://localhost:\(appState.config.backendPort)"
        default: return nil
        }
    }

    private var visibleServices: [ServiceInfo] {
        appState.services.filter { service in
            if service.id == "litellm" && !appState.config.deployLiteLLM { return false }
            if service.id == "hindsight" && !appState.config.useHindsight { return false }
            if service.id == "gdrive-mcp" && !appState.config.useGoogleDrive { return false }
            if service.id == "onedrive-mcp" && !appState.config.useOneDrive { return false }
            return true
        }
    }

    private var serviceList: some View {
        VStack(spacing: 2) {
            ForEach(visibleServices) { service in
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
                    } else if service.status == .running, let urlString = webUIURL(for: service.id) {
                        Button {
                            openWebUI(serviceId: service.id, urlString: urlString)
                        } label: {
                            Text("Open")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
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

    /// Opens a service's web UI. For LiteLLM, opens via the BridgeServer's login
    /// endpoint which auto-authenticates using the master key.
    private func openWebUI(serviceId: String, urlString: String) {
        if serviceId == "litellm" {
            // The BridgeServer serves an auto-login page at /litellm-login that
            // POSTs to LiteLLM's /v2/login, sets the auth cookie on localhost,
            // and redirects to the UI — no manual login needed.
            if let url = URL(string: "http://localhost:9876/litellm-login") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button("Start All") {
                    appState.startAllInBackground()
                }
                .disabled(appState.appStatus == .starting)

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
