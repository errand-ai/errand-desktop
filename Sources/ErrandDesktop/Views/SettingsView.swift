import SwiftUI
import ServiceManagement

/// Settings window for API keys, OIDC config, LiteLLM toggle, ports.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralTab()
                .environmentObject(appState)
                .tabItem { Label("General", systemImage: "gear") }
            LLMTab()
                .environmentObject(appState)
                .tabItem { Label("LLM", systemImage: "brain") }
            OIDCTab()
                .environmentObject(appState)
                .tabItem { Label("OIDC", systemImage: "lock.shield") }
            PortsTab()
                .environmentObject(appState)
                .tabItem { Label("Ports", systemImage: "network") }
        }
        .frame(width: 450, height: 300)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var appState: AppState
    @State private var isUpdatingLoginItem = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $appState.config.launchAtLogin)
                .onChange(of: appState.config.launchAtLogin) { _, enabled in
                    guard !isUpdatingLoginItem else {
                        isUpdatingLoginItem = false
                        return
                    }
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        isUpdatingLoginItem = true
                        appState.config.launchAtLogin = !enabled
                    }
                }

            LabeledContent("Image Tag") {
                TextField("Tag", text: $appState.config.contentManagerImageTag)
                    .frame(width: 200)
            }

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
    }
}

// MARK: - LLM

private struct LLMTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            LabeledContent("Base URL") {
                TextField("https://api.openai.com/v1", text: $appState.config.openaiBaseURL)
                    .frame(width: 250)
            }

            LabeledContent("API Key") {
                SecureField("sk-...", text: $appState.config.openaiAPIKey)
                    .frame(width: 250)
            }

            Divider()

            Toggle("Enable LiteLLM Proxy", isOn: $appState.config.litellmEnabled)

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
    }
}

// MARK: - OIDC

private struct OIDCTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            LabeledContent("Discovery URL") {
                TextField("https://...", text: $appState.config.oidcDiscoveryURL)
                    .frame(width: 250)
            }

            LabeledContent("Client ID") {
                TextField("Client ID", text: $appState.config.oidcClientID)
                    .frame(width: 250)
            }

            LabeledContent("Client Secret") {
                SecureField("Secret", text: $appState.config.oidcClientSecret)
                    .frame(width: 250)
            }

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
    }
}

// MARK: - Ports

private struct PortsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            portField("Backend Port", value: $appState.config.backendPort)
            portField("PostgreSQL Port", value: $appState.config.postgresPort)
            portField("Valkey Port", value: $appState.config.valkeyPort)
            portField("LiteLLM Port", value: $appState.config.litellmPort)

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
    }

    private func portField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) {
            TextField("", value: value, format: .number)
                .frame(width: 80)
                .monospacedDigit()
        }
    }
}
