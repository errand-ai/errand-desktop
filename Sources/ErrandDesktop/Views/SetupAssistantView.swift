import SwiftUI

/// First-run setup assistant for API keys and image pulling.
struct SetupAssistantView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var isPulling = false
    @State private var isStartingSetupServices = false
    @State private var setupServiceError: String?
    @State private var chatModels: [AppState.ModelInfo] = []
    @State private var embeddingModels: [AppState.ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var modelFetchError = false
    @State private var availableTags: [String] = []
    @State private var isLoadingTags = false
    @State private var tagFetchError = false
    @State private var isCheckingDocker = false
    @State private var isDetectingProvider = false
    @State private var providerDetectionDone = false

    // Steps: 0=Welcome, 1=Runtime, 2=LLM Config, 3=LLM Start, 4=Agent Memory, 5=Version, 6=Image Pull, 7=Done
    private let totalSteps = 8

    var body: some View {
        VStack(spacing: 0) {
            // Step indicators — hide the LLM Start dot (step 3) when not deploying LiteLLM locally
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    if i != 3 || appState.config.deployLiteLLM {
                        Circle()
                            .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .padding(.top, 16)

            // Step content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: runtimeStep
                case 2: llmConfigStep
                case 3: llmStartStep
                case 4: agentMemoryStep
                case 5: versionStep
                case 6: imagePullStep
                case 7: doneStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)

            Divider()

            // Navigation
            HStack {
                if step > 0 && step < totalSteps - 1 {
                    Button("Back") {
                        if step == 4 && !appState.config.deployLiteLLM {
                            step = 2  // Skip back over LLM Start step
                        } else {
                            step -= 1
                        }
                    }
                    .disabled(isPulling || isStartingSetupServices)
                }

                Spacer()

                if step < totalSteps - 1 {
                    Button("Continue") {
                        if step == 2 && !appState.config.deployLiteLLM {
                            step = 4  // Skip LLM Start step
                        } else {
                            step += 1
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPulling || isStartingSetupServices)
                } else {
                    Button("Finish") {
                        appState.completeFirstRun()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 500, height: 480)
        .onAppear {
            // Menu bar apps (LSUIElement) can't receive keyboard focus by default.
            // Temporarily become a regular app so the window can accept key input.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for window in NSApp.windows where window.isVisible {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        .onDisappear {
            // Revert to accessory (menu-bar-only) when setup closes
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            if let url = Bundle.module.url(forResource: "errand-logo", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
            }

            Text("Welcome to Errand Desktop")
                .font(.title2.weight(.semibold))

            Text("This app runs the Errand AI stack locally using lightweight Linux containers on your Mac.\n\nLet's configure a few things to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var runtimeStep: some View {
        let installable = RuntimeDetector.detectInstallable()

        return VStack(alignment: .leading, spacing: 16) {
            Text("Container Runtime")
                .font(.title2.weight(.semibold))

            Text("Choose how Errand runs containers on your Mac.")
                .foregroundStyle(.secondary)

            ForEach(installable, id: \.rawValue) { runtime in
                let isAvailable = appState.availableRuntimes.contains(runtime)
                let isSelected = appState.config.containerRuntime == runtime.rawValue

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected && isAvailable ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected && isAvailable ? Color.accentColor : Color.secondary)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(runtime.displayName)
                                .font(.headline)
                            if runtime == .docker {
                                Text("(Recommended)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(runtime.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !isAvailable {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                Text(runtime == .docker ? "Docker is not running" : "Not available on this Mac")
                                    .font(.caption)
                            }
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                        }
                    }
                }
                .opacity(isAvailable ? 1.0 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isAvailable else { return }
                    appState.config.containerRuntime = runtime.rawValue
                    appState.activeRuntime = runtime
                }
            }

            if !appState.availableRuntimes.contains(.docker) {
                HStack(spacing: 12) {
                    Button("Download Docker") {
                        if let url = URL(string: "https://www.docker.com/products/docker-desktop/") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    Button("Check Again") {
                        isCheckingDocker = true
                        Task {
                            appState.availableRuntimes = await RuntimeDetector.detectAvailable()
                            if let preferred = RuntimeDetector.defaultRuntime(from: appState.availableRuntimes) {
                                appState.config.containerRuntime = preferred.rawValue
                                appState.activeRuntime = preferred
                            }
                            isCheckingDocker = false
                        }
                    }
                    .disabled(isCheckingDocker)

                    if isCheckingDocker {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - LLM Configuration (choices only, no container startup)

    private var llmConfigStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LLM Provider")
                .font(.title2.weight(.semibold))

            Text("Errand needs access to an LLM provider for AI tasks.")
                .foregroundStyle(.secondary)

            // Radio choice
            VStack(alignment: .leading, spacing: 12) {
                radioRow(
                    selected: appState.config.deployLiteLLM,
                    title: "Deploy LiteLLM locally",
                    subtitle: "Route requests through a local LiteLLM proxy that supports multiple AI providers.",
                    recommended: true
                ) {
                    appState.config.deployLiteLLM = true
                }

                radioRow(
                    selected: !appState.config.deployLiteLLM,
                    title: "Connect to an existing provider",
                    subtitle: "Provide the Base URL and API key for an OpenAI-compatible API endpoint.",
                    recommended: false
                ) {
                    appState.config.deployLiteLLM = false
                }
            }

            if !appState.config.deployLiteLLM {
                Form {
                    LabeledContent("Name") {
                        TextField("", text: $appState.config.llmProviderName, prompt: Text("e.g. OpenAI, Ollama"))
                            .frame(width: 250)
                    }

                    LabeledContent("Base URL") {
                        TextField("", text: $appState.config.llmProviderBaseURL, prompt: Text("https://api.openai.com/v1"))
                            .frame(width: 250)
                            .onChange(of: appState.config.llmProviderBaseURL) {
                                providerDetectionDone = false
                            }
                    }

                    LabeledContent("API Key") {
                        SecureField("", text: $appState.config.llmProviderAPIKey, prompt: Text("sk-...."))
                            .frame(width: 250)
                            .onChange(of: appState.config.llmProviderAPIKey) {
                                providerDetectionDone = false
                            }
                    }
                }

                if isDetectingProvider {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Detecting provider type...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if providerDetectionDone, !appState.config.llmProviderType.isEmpty {
                    let label = providerTypeLabel(appState.config.llmProviderType)
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Detected: \(label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !appState.config.llmProviderBaseURL.isEmpty && !appState.config.llmProviderAPIKey.isEmpty && !providerDetectionDone && !isDetectingProvider {
                    Button("Detect Provider") {
                        runProviderDetection()
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 2) {
                Text("Learn more:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("errand.sh/docs/ai-models/", destination: URL(string: "https://errand.sh/docs/ai-models/")!)
                    .font(.caption)
            }
        }
    }

    private func radioRow(selected: Bool, title: String, subtitle: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    if recommended {
                        Text("(Recommended)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func runProviderDetection() {
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

    // MARK: - LLM Services Start (only reached if LiteLLM is enabled)

    private var llmStartStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Starting LiteLLM Services")
                .font(.title2.weight(.semibold))

            Text("Pulling images and starting Postgres and LiteLLM containers.")
                .foregroundStyle(.secondary)

            if isStartingSetupServices {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["postgres", "litellm"], id: \.self) { serviceId in
                        if let service = appState.services.first(where: { $0.id == serviceId }) {
                            HStack {
                                Text(service.displayName)
                                    .frame(width: 90, alignment: .leading)
                                switch service.status {
                                case .pulling:
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Pulling image...")
                                        .foregroundStyle(.secondary)
                                case .preparing:
                                    if let progress = service.preparingProgress {
                                        ProgressView(value: progress)
                                            .frame(width: 60)
                                        Text("\(Int(progress * 100))%")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    } else {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Preparing...")
                                            .foregroundStyle(.secondary)
                                    }
                                case .starting:
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Starting...")
                                        .foregroundStyle(.secondary)
                                case .running:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Running")
                                        .foregroundStyle(.secondary)
                                case .error:
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Text("Error")
                                        .foregroundStyle(.red)
                                default:
                                    Text("Waiting...")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if let error = setupServiceError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                    Button("Retry") {
                        startLiteLLMServices()
                    }
                }
            }

            let litellmRunning = appState.services.first(where: { $0.id == "litellm" })?.status == .running

            if litellmRunning {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Open LiteLLM UI") {
                        if let url = URL(string: "http://localhost:\(appState.config.litellmPort)/ui") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    if let masterKey = try? KeychainManager.getOrCreateLiteLLMKey() {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Login credentials:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Text("Username:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("admin")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            HStack(spacing: 4) {
                                Text("Password:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(masterKey)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .task {
            let litellmRunning = appState.services.first(where: { $0.id == "litellm" })?.status == .running
            guard !litellmRunning && !isStartingSetupServices else { return }
            startLiteLLMServices()
        }
    }

    private func startLiteLLMServices() {
        setupServiceError = nil
        isStartingSetupServices = true
        Task {
            do {
                try await appState.startSetupServices()
            } catch {
                setupServiceError = "Failed to start services: \(error.localizedDescription)"
            }
            isStartingSetupServices = false
        }
    }

    private var agentMemoryStep: some View {
        let providerType = effectiveProviderType

        return VStack(alignment: .leading, spacing: 16) {
            Text("Agent Memory")
                .font(.title2.weight(.semibold))

            Text("Hindsight gives your AI agents persistent memory across tasks and conversations.")
                .foregroundStyle(.secondary)

            Toggle("Use Hindsight for Agent Memory", isOn: $appState.config.useHindsight)

            if appState.config.useHindsight {
                if isLoadingModels {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading available models...")
                            .foregroundStyle(.secondary)
                    }
                }

                if modelFetchError {
                    HStack {
                        Text("Failed to load models.")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Button("Retry") {
                            fetchModels()
                        }
                    }
                }
            }

            Form {
                if providerType == .unknown {
                    LabeledContent("LLM Model") {
                        TextField("", text: $appState.config.hindsightLLMModel, prompt: Text("e.g. gpt-4o"))
                            .frame(width: 250)
                            .disabled(!appState.config.useHindsight)
                    }

                    LabeledContent("Embedding Model") {
                        TextField("", text: $appState.config.hindsightEmbeddingModel, prompt: Text("e.g. text-embedding-3-small"))
                            .frame(width: 250)
                            .disabled(!appState.config.useHindsight)
                    }
                } else {
                    LabeledContent("LLM Model") {
                        Picker("", selection: $appState.config.hindsightLLMModel) {
                            Text("Select a model").tag("")
                            ForEach(chatModels) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 250)
                        .disabled(!appState.config.useHindsight)
                    }

                    LabeledContent("Embedding Model") {
                        Picker("", selection: $appState.config.hindsightEmbeddingModel) {
                            Text("Select a model").tag("")
                            ForEach(embeddingModels) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 250)
                        .disabled(!appState.config.useHindsight)
                    }
                }
            }
            .opacity(appState.config.useHindsight ? 1.0 : 0.5)

            HStack(spacing: 2) {
                Text("Learn more:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("errand.sh/docs/ai-memory/", destination: URL(string: "https://errand.sh/docs/ai-memory/")!)
                    .font(.caption)
            }
        }
        .task(id: appState.config.useHindsight) {
            guard appState.config.useHindsight else { return }
            fetchModels()
        }
    }

    /// Services to show in the image pull step, excluding disabled ones.
    private var visibleServices: [ServiceInfo] {
        appState.services.filter { service in
            if service.id == "litellm" && !appState.config.deployLiteLLM { return false }
            if service.id == "hindsight" && !appState.config.useHindsight { return false }
            if service.id == "gdrive-mcp" && !appState.config.useGoogleDrive { return false }
            if service.id == "onedrive-mcp" && !appState.config.useOneDrive { return false }
            return true
        }
    }

    /// The effective provider type — litellm if deploying locally, otherwise from config.
    private var effectiveProviderType: ProviderType {
        if appState.config.deployLiteLLM {
            return .litellm
        }
        return ProviderType(rawValue: appState.config.llmProviderType) ?? .unknown
    }

    private func fetchModels() {
        isLoadingModels = true
        modelFetchError = false
        Task {
            let (chat, embedding) = await appState.fetchAvailableModels()
            chatModels = chat
            embeddingModels = embedding
            modelFetchError = chat.isEmpty && embedding.isEmpty

            // Auto-select claude-sonnet if available
            if appState.config.hindsightLLMModel.isEmpty,
               let sonnet = chat.first(where: { $0.id.hasPrefix("claude-sonnet") }) {
                appState.config.hindsightLLMModel = sonnet.id
            }

            isLoadingModels = false
        }
    }

    private var versionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Image Version")
                .font(.title2.weight(.semibold))

            Text("Select which version of the Errand stack to install.")
                .foregroundStyle(.secondary)

            if isLoadingTags {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching available versions...")
                        .foregroundStyle(.secondary)
                }
            }

            if tagFetchError {
                HStack {
                    Text("Failed to fetch versions.")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Button("Retry") {
                        fetchTags()
                    }
                }
            }

            Form {
                LabeledContent("Version") {
                    Picker("", selection: $appState.config.contentManagerImageTag) {
                        if !availableTags.contains(appState.config.contentManagerImageTag) && !appState.config.contentManagerImageTag.isEmpty {
                            Text(appState.config.contentManagerImageTag)
                                .tag(appState.config.contentManagerImageTag)
                        }
                        ForEach(availableTags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                    .disabled(availableTags.isEmpty)
                }

                Toggle("Show beta versions", isOn: $appState.config.showBetaVersions)
                    .onChange(of: appState.config.showBetaVersions) {
                        fetchTags()
                    }
            }
        }
        .task {
            guard availableTags.isEmpty else { return }
            fetchTags()
        }
    }

    private func fetchTags() {
        isLoadingTags = true
        tagFetchError = false
        Task {
            do {
                var tags = try await GHCRTagFetcher.fetchTags(
                    image: "errand-ai/errand",
                    includeBeta: appState.config.showBetaVersions,
                    minimumVersion: "0.82.0"
                )
                // Remove "latest" unless it's an actual tag returned from GHCR
                // (GHCRTagFetcher already filters and sorts by semver descending)
                tags = tags.filter { $0 != "latest" }
                availableTags = tags

                // Auto-select the highest semver version (first in the sorted list)
                if let first = tags.first,
                   appState.config.contentManagerImageTag == "latest" || !tags.contains(appState.config.contentManagerImageTag) {
                    appState.config.contentManagerImageTag = first
                }
            } catch {
                tagFetchError = true
                appState.appendLog(service: "system", message: "Failed to fetch image tags: \(error.localizedDescription)")
            }
            isLoadingTags = false
        }
    }

    private var imagePullStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pulling Container Images")
                .font(.title2.weight(.semibold))

            Text("Downloading the required container images. This may take a few minutes.")
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(visibleServices) { service in
                    let progress = appState.imagePullProgress[service.id] ?? 0

                    HStack {
                        Text(service.displayName)
                            .frame(width: 90, alignment: .leading)

                        ProgressView(value: progress)

                        if progress >= 1.0 {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .task {
            let allPulled = !appState.imagePullProgress.isEmpty
                && appState.imagePullProgress.values.allSatisfy { $0 >= 1.0 }
            guard !allPulled else { return }
            isPulling = true
            await appState.pullRequiredImages()
            isPulling = false
        }
    }

    private var doneStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title2.weight(.semibold))

            Text("Your services are starting up now. Click the menu bar icon to see their status.")
                .foregroundStyle(.secondary)
        }
    }
}
