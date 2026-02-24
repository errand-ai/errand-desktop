import SwiftUI
import ServiceManagement

/// Settings window for API keys, memory model config, and ports.
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
            MemoryTab()
                .environmentObject(appState)
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
            PortsTab()
                .environmentObject(appState)
                .tabItem { Label("Ports", systemImage: "network") }
        }
        .frame(width: 450, height: 300)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for window in NSApp.windows where window.isVisible {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var appState: AppState
    @State private var isUpdatingLoginItem = false
    @State private var availableTags: [String] = []
    @State private var isLoadingTags = false

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
                HStack(spacing: 6) {
                    Picker("", selection: $appState.config.contentManagerImageTag) {
                        if !availableTags.contains(appState.config.contentManagerImageTag) {
                            Text(appState.config.contentManagerImageTag)
                                .tag(appState.config.contentManagerImageTag)
                        }
                        ForEach(availableTags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    if isLoadingTags {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(action: { Task { await fetchTags() } }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Toggle("Show beta versions", isOn: $appState.config.showBetaVersions)
                .onChange(of: appState.config.showBetaVersions) {
                    Task { await fetchTags() }
                }

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
        .task { await fetchTags() }
    }

    private func fetchTags() async {
        isLoadingTags = true
        defer { isLoadingTags = false }
        do {
            availableTags = try await GHCRTagFetcher.fetchTags(
                image: "errand-ai/errand",
                includeBeta: appState.config.showBetaVersions
            )
        } catch {
            print("[GeneralTab] Failed to fetch tags: \(error)")
        }
    }
}

// MARK: - LLM

private struct LLMTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Toggle("Use LiteLLM", isOn: $appState.config.useLiteLLM)

            LabeledContent("Base URL") {
                TextField("", text: $appState.config.openaiBaseURL, prompt: Text("https://api.openai.com/v1"))
                    .frame(width: 250)
                    .disabled(appState.config.useLiteLLM)
            }
            .opacity(appState.config.useLiteLLM ? 0.5 : 1.0)

            LabeledContent("API Key") {
                SecureField("", text: $appState.config.openaiAPIKey, prompt: Text("sk-...."))
                    .frame(width: 250)
                    .disabled(appState.config.useLiteLLM)
            }
            .opacity(appState.config.useLiteLLM ? 0.5 : 1.0)

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
    }
}

// MARK: - Memory

private struct MemoryTab: View {
    @EnvironmentObject var appState: AppState
    @State private var chatModels: [AppState.ModelInfo] = []
    @State private var embeddingModels: [AppState.ModelInfo] = []
    @State private var isLoadingModels = false

    var body: some View {
        Form {
            Toggle("Use Hindsight for Agent Memory", isOn: $appState.config.useHindsight)

            LabeledContent("LLM Model") {
                Picker("", selection: $appState.config.hindsightLLMModel) {
                    Text("Select a model").tag("")
                    ForEach(chatModels) { model in
                        Text(model.id).tag(model.id)
                    }
                    // Keep current value visible even if not yet in fetched list
                    if !appState.config.hindsightLLMModel.isEmpty,
                       !chatModels.contains(where: { $0.id == appState.config.hindsightLLMModel }) {
                        Text(appState.config.hindsightLLMModel).tag(appState.config.hindsightLLMModel)
                    }
                }
                .labelsHidden()
                .frame(width: 250)
                .disabled(!appState.config.useHindsight)
            }
            .opacity(appState.config.useHindsight ? 1.0 : 0.5)

            LabeledContent("Embedding Model") {
                Picker("", selection: $appState.config.hindsightEmbeddingModel) {
                    Text("Select a model").tag("")
                    ForEach(embeddingModels) { model in
                        Text(model.id).tag(model.id)
                    }
                    if !appState.config.hindsightEmbeddingModel.isEmpty,
                       !embeddingModels.contains(where: { $0.id == appState.config.hindsightEmbeddingModel }) {
                        Text(appState.config.hindsightEmbeddingModel).tag(appState.config.hindsightEmbeddingModel)
                    }
                }
                .labelsHidden()
                .frame(width: 250)
                .disabled(!appState.config.useHindsight)
            }
            .opacity(appState.config.useHindsight ? 1.0 : 0.5)

            if isLoadingModels {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading models...")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
        .task {
            guard appState.config.useHindsight else { return }
            await loadModels()
        }
        .onChange(of: appState.config.useHindsight) { _, enabled in
            if enabled {
                Task { await loadModels() }
            }
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        let (chat, embedding) = await appState.fetchAvailableModels()
        chatModels = chat
        embeddingModels = embedding
        isLoadingModels = false
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
            portField("Hindsight Port", value: $appState.config.hindsightPort)

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
    }

    private func portField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) {
            TextField("", value: value, format: .number.grouping(.never))
                .frame(width: 80)
                .monospacedDigit()
        }
    }
}
