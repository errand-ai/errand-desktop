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
            ServicesTab()
                .environmentObject(appState)
                .tabItem { Label("Services", systemImage: "square.stack.3d.up") }
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
            // Runtime selection
            if appState.availableRuntimes.count > 1 {
                LabeledContent("Container Runtime") {
                    Picker("", selection: $appState.config.containerRuntime) {
                        ForEach(appState.availableRuntimes, id: \.rawValue) { runtime in
                            Text(runtime.displayName).tag(runtime.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Text("Changing the runtime requires restarting all services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let active = appState.activeRuntime {
                LabeledContent("Container Runtime") {
                    Text(active.displayName)
                        .foregroundStyle(.secondary)
                }
            }

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
                includeBeta: appState.config.showBetaVersions,
                minimumVersion: "0.82.0"
            )
        } catch {
            print("[GeneralTab] Failed to fetch tags: \(error)")
        }
    }
}

// MARK: - LLM

private struct LLMTab: View {
    @EnvironmentObject var appState: AppState
    @State private var isDetectingProvider = false
    @State private var providerDetectionDone = false

    var body: some View {
        Form {
            // Radio choice
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: appState.config.deployLiteLLM ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(appState.config.deployLiteLLM ? Color.accentColor : Color.secondary)
                Text("Deploy LiteLLM locally")
                    .font(.headline)
                Text("(Recommended)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.config.deployLiteLLM = true }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: !appState.config.deployLiteLLM ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(!appState.config.deployLiteLLM ? Color.accentColor : Color.secondary)
                Text("Connect to an existing provider")
                    .font(.headline)
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.config.deployLiteLLM = false }

            if !appState.config.deployLiteLLM {
                LabeledContent("Name") {
                    TextField("", text: $appState.config.llmProviderName, prompt: Text("e.g. OpenAI, Ollama"))
                        .frame(width: 200)
                }

                LabeledContent("Base URL") {
                    TextField("", text: $appState.config.llmProviderBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .frame(width: 200)
                        .onChange(of: appState.config.llmProviderBaseURL) {
                            providerDetectionDone = false
                        }
                }

                LabeledContent("API Key") {
                    SecureField("", text: $appState.config.llmProviderAPIKey, prompt: Text("sk-...."))
                        .frame(width: 200)
                        .onChange(of: appState.config.llmProviderAPIKey) {
                            providerDetectionDone = false
                        }
                }

                if isDetectingProvider {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Detecting...").font(.caption).foregroundStyle(.secondary)
                    }
                } else if !appState.config.llmProviderType.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                        Text("Detected: \(providerTypeLabel(appState.config.llmProviderType))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !appState.config.llmProviderBaseURL.isEmpty && !appState.config.llmProviderAPIKey.isEmpty && !providerDetectionDone && !isDetectingProvider {
                    Button("Detect Provider") {
                        runDetection()
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 2) {
                Text("Learn more:")
                    .font(.caption).foregroundStyle(.secondary)
                Link("errand.sh/docs/ai-models/", destination: URL(string: "https://errand.sh/docs/ai-models/")!)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
    }

    private func runDetection() {
        isDetectingProvider = true
        providerDetectionDone = false
        Task {
            let result = await ProviderDetector.detect(
                baseURL: appState.config.llmProviderBaseURL,
                apiKey: appState.config.llmProviderAPIKey
            )
            appState.config.llmProviderType = result.rawValue
            isDetectingProvider = false
            providerDetectionDone = true
        }
    }

    private func providerTypeLabel(_ type: String) -> String {
        switch type {
        case "litellm": return "LiteLLM"
        case "openai_compatible": return "OpenAI-compatible"
        default: return "Unknown provider"
        }
    }
}

// MARK: - Memory

private struct MemoryTab: View {
    @EnvironmentObject var appState: AppState
    @State private var chatModels: [AppState.ModelInfo] = []
    @State private var embeddingModels: [AppState.ModelInfo] = []
    @State private var isLoadingModels = false

    private var providerType: ProviderType {
        if appState.config.deployLiteLLM { return .litellm }
        return ProviderType(rawValue: appState.config.llmProviderType) ?? .unknown
    }

    var body: some View {
        Form {
            Toggle("Use Hindsight for Agent Memory", isOn: $appState.config.useHindsight)

            if providerType == .unknown {
                LabeledContent("LLM Model") {
                    TextField("", text: $appState.config.hindsightLLMModel, prompt: Text("e.g. gpt-4o"))
                        .frame(width: 250)
                        .disabled(!appState.config.useHindsight)
                }
                .opacity(appState.config.useHindsight ? 1.0 : 0.5)

                LabeledContent("Embedding Model") {
                    TextField("", text: $appState.config.hindsightEmbeddingModel, prompt: Text("e.g. text-embedding-3-small"))
                        .frame(width: 250)
                        .disabled(!appState.config.useHindsight)
                }
                .opacity(appState.config.useHindsight ? 1.0 : 0.5)
            } else {
                LabeledContent("LLM Model") {
                    Picker("", selection: $appState.config.hindsightLLMModel) {
                        Text("Select a model").tag("")
                        ForEach(chatModels) { model in
                            Text(model.id).tag(model.id)
                        }
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
            }

            if isLoadingModels {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading models...")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 2) {
                Text("Learn more:")
                    .font(.caption).foregroundStyle(.secondary)
                Link("errand.sh/docs/ai-memory/", destination: URL(string: "https://errand.sh/docs/ai-memory/")!)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Save") { appState.saveConfig() }
            }
        }
        .padding()
        .task {
            guard appState.config.useHindsight, providerType != .unknown else { return }
            await loadModels()
        }
        .onChange(of: appState.config.useHindsight) { _, enabled in
            if enabled && providerType != .unknown {
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

// MARK: - Services

private struct ServicesTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Cloud Storage") {
                Toggle("Google Drive MCP Server", isOn: $appState.config.useGoogleDrive)
                Toggle("OneDrive MCP Server", isOn: $appState.config.useOneDrive)

                Text("Enables agents to access cloud storage files. OAuth credentials must be configured in the Errand backend Settings > Integrations page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
