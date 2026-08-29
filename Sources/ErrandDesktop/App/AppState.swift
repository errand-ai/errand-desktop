import Foundation
import SwiftUI

/// Central app state shared across views. Manages services, config, and orchestration.
@MainActor
class AppState: ObservableObject {
    @Published var services: [ServiceInfo] = [
        ServiceInfo(id: "postgres", displayName: "PostgreSQL", port: 5432),
        ServiceInfo(id: "valkey", displayName: "Valkey", port: 6379),
        ServiceInfo(id: "migrate", displayName: "Migrate", isEphemeral: true),
        ServiceInfo(id: "gdrive-mcp", displayName: "Google Drive MCP"),
        ServiceInfo(id: "onedrive-mcp", displayName: "OneDrive MCP"),
        ServiceInfo(id: "litellm", displayName: "LiteLLM", port: 4000),
        ServiceInfo(id: "hindsight", displayName: "Hindsight", port: 9999),
        ServiceInfo(id: "playwright", displayName: "Playwright"),
        ServiceInfo(id: "backend", displayName: "Errand Service", port: 8000),
    ]

    @Published var config: AppConfig = AppConfig()
    @Published var isFirstRun: Bool = false
    @Published var logs: [LogEntry] = []
    @Published var selectedLogService: String? = nil

    /// Upper bound on retained in-memory log entries. Oldest entries are
    /// discarded past this cap to keep memory bounded during long sessions.
    private let maxLogEntries = 10_000
    @Published var migrationError: String?
    @Published var keychainError: String?
    @Published var runtimeError: String?
    @Published var litellmMasterKeyDisplay: String = ""
    @Published var imagePullProgress: [String: Double] = [:]
    @Published var availableRuntimes: [RuntimeCapability] = []
    @Published var activeRuntime: RuntimeCapability?

    private var containerEngine: ContainerEngine?
    private var storageManager: StorageManager?
    private var bridgeServer: BridgeServer?
    private var healthChecker: HealthChecker?
    private(set) var liteLLMManager: LiteLLMManager?
    private var migrationRunner: MigrationRunner?
    private var portForwarder = PortForwarder()
    private(set) var updateChecker = UpdateChecker()
    private var startTask: Task<Void, Error>?

    /// Overall status derived from service states.
    var appStatus: AppStatus {
        // Exclude ephemeral services (like migrate) from status calculation
        let longRunning = services.filter { !$0.isEphemeral }
        let running = longRunning.filter { $0.status == .running }
        let starting = longRunning.filter { $0.status == .starting || $0.status == .pulling || $0.status == .preparing }
        let errored = longRunning.filter { $0.status == .error }

        if running.isEmpty && starting.isEmpty { return .idle }
        if !starting.isEmpty { return .starting }
        if !errored.isEmpty { return .degraded }
        return .running
    }

    /// SF Symbol name for the menu bar icon based on current status.
    var menuBarIconName: String {
        switch appStatus {
        case .idle: return "tray"
        case .starting: return "tray.and.arrow.down"
        case .running: return "tray.fill"
        case .degraded: return "exclamationmark.triangle"
        }
    }

    private var initialized = false

    func initialize() async {
        guard !initialized else { return }
        initialized = true

        print("[AppState] Initializing...")
        storageManager = StorageManager()
        storageManager?.ensureDataDirectories()

        if let loaded = storageManager?.loadConfig() {
            config = loaded
        } else {
            isFirstRun = true
        }

        containerEngine = ContainerEngine()
        bridgeServer = BridgeServer(containerEngine: containerEngine!)
        healthChecker = HealthChecker(appState: self, containerEngine: containerEngine!)
        liteLLMManager = LiteLLMManager()
        migrationRunner = MigrationRunner(containerEngine: containerEngine!)

        // Detect available runtimes and configure the engine
        await detectAndSetRuntime()

        // Pass bridge API credentials to ContainerEngine so it can inject them into the worker
        if let token = await bridgeServer?.authToken {
            await containerEngine?.setBridgeCredentials(token: token, port: 9876)
        }

        // Request notification authorization early
        await NotificationManager.requestAuthorization()

        // Load secrets from the macOS Keychain (needed for both setup wizard and normal startup)
        await loadKeychainSecrets()

        // On first run, stop here — the setup wizard handles the rest.
        guard !isFirstRun else { return }

        // Load persisted LiteLLM providers
        await liteLLMManager?.loadProviders()

        // Start checking for updates
        updateChecker.startPeriodicChecks()

        // Auto-start containers if enabled
        if config.autoStartContainers && keychainError == nil && runtimeError == nil {
            startAllInBackground()
        }
    }

    /// Detects available runtimes and configures the container engine with the preferred one.
    func detectAndSetRuntime() async {
        availableRuntimes = await RuntimeDetector.detectAvailable()

        // Determine which runtime to use: prefer user's saved config, fall back to auto-detect
        let preferred = RuntimeCapability(rawValue: config.containerRuntime)
        let chosen: RuntimeCapability?
        if let preferred, availableRuntimes.contains(preferred) {
            chosen = preferred
        } else {
            chosen = RuntimeDetector.defaultRuntime(from: availableRuntimes)
        }

        guard let chosen else {
            let msg = "No container runtime available. Install Docker Desktop or upgrade to macOS 26 on Apple Silicon."
            runtimeError = msg
            appendLog(service: "system", message: msg)
            return
        }

        runtimeError = nil
        activeRuntime = chosen

        // Update config if it was overridden
        if config.containerRuntime != chosen.rawValue {
            config.containerRuntime = chosen.rawValue
            saveConfig()
        }

        do {
            let runtime: any ContainerRuntime
            switch chosen {
            case .docker:
                let socketPath = await RuntimeDetector.findDockerSocket() ?? "/var/run/docker.sock"
                runtime = DockerRuntime(socketPath: socketPath)
                appendLog(service: "system", message: "Docker socket: \(socketPath)")
            case .appleContainerization:
                runtime = AppleContainerRuntime()
            }
            try await containerEngine?.setRuntime(runtime, capability: chosen)
            appendLog(service: "system", message: "Container runtime: \(chosen.displayName)")
        } catch {
            appendLog(service: "system", message: "Failed to initialize \(chosen.displayName) runtime: \(error.localizedDescription)")
        }
    }

    /// Loads the credential encryption key, LiteLLM master key, and LiteLLM salt key
    /// from the macOS Keychain. Retries up to 3 times with a 1-second delay (the keychain
    /// may be briefly locked after login).
    /// Sets `keychainError` if all attempts fail — callers must check this before starting containers.
    private func loadKeychainSecrets() async {
        keychainError = nil
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            do {
                let encKey = try KeychainManager.getOrCreate(account: "credential-encryption-key")
                let masterKey = try KeychainManager.getOrCreateLiteLLMKey()
                let saltKey = try KeychainManager.getOrCreateLiteLLMSaltKey()
                let pgPassword = try KeychainManager.getOrCreatePostgresPassword()
                await containerEngine?.setCredentialEncryptionKey(encKey)
                await containerEngine?.setLiteLLMMasterKey(masterKey)
                await containerEngine?.setLiteLLMSaltKey(saltKey)
                await containerEngine?.setPostgresPassword(pgPassword)
                litellmMasterKeyDisplay = masterKey
                appendLog(service: "system", message: "Keychain secrets loaded successfully")
                return
            } catch {
                let msg = "Keychain attempt \(attempt)/\(maxAttempts) failed: \(error)"
                appendLog(service: "system", message: msg)
                try? msg.appending("\n").write(toFile: "/tmp/errand-keychain.log", atomically: true, encoding: .utf8)
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        let errorMsg = "Unable to read secrets from the macOS Keychain after \(maxAttempts) attempts. Services cannot start without encryption keys."
        keychainError = errorMsg
        appendLog(service: "system", message: errorMsg)
        await NotificationManager.postKeychainError(errorMsg)
    }

    /// Retries loading keychain secrets (called from UI after user dismisses error).
    func retryKeychainLoad() async {
        await loadKeychainSecrets()
    }

    /// Launches startAll in a cancellable background task.
    func startAllInBackground() {
        startTask = Task {
            do {
                try await startAll()
            } catch is CancellationError {
                appendLog(service: "app", message: "Startup cancelled")
            } catch {
                appendLog(service: "app", message: "Start failed: \(error)")
            }
        }
    }

    func startAll() async throws {
        migrationError = nil

        // Refuse to start if no runtime or keychain secrets are missing
        if runtimeError != nil {
            throw AppError.noRuntime
        }
        if keychainError != nil {
            throw AppError.keychainNotReady
        }

        // Start the bridge API server so the worker can create task-runner containers.
        // Pass the vmnet gateway IP so the bridge accepts worker connections from
        // the container subnet while rejecting arbitrary LAN hosts.
        let gatewayIP = await containerEngine?.hostGateway()
        try await bridgeServer?.start(allowedGatewayIP: gatewayIP)

        // Clear existing port forwards before starting fresh (Docker publishes ports natively)
        let needsPortForwarding = activeRuntime != .docker
        if needsPortForwarding {
            await portForwarder.stopAll()
        }

        // Start services in dependency order with UI progress updates.
        // Port forwarding is set up incrementally as each service becomes running,
        // so earlier services are reachable while later ones are still starting.
        if let engine = containerEngine {
            services = try await engine.startAll(
                services: services,
                config: config,
                onStatus: { [weak self] id, status, containerIP in
                    Task { @MainActor in
                        guard let self else { return }
                        if let idx = self.services.firstIndex(where: { $0.id == id }) {
                            self.services[idx].status = status
                            if let containerIP {
                                self.services[idx].containerIP = containerIP
                            }

                            // Set up port forwarding (Apple Containerization only) and notify
                            if status == .running {
                                let service = self.services[idx]
                                if needsPortForwarding, let port = service.port, let ip = service.containerIP {
                                    let remotePort = service.containerPort ?? port
                                    do {
                                        try await self.portForwarder.forward(localPort: port, to: ip, remotePort: remotePort)
                                    } catch {
                                        self.appendLog(service: id, message: "Port forwarding failed for port \(port): \(error.localizedDescription)")
                                    }
                                    // Hindsight exposes both a UI (9999) and API (8888)
                                    if id == "hindsight" {
                                        do {
                                            try await self.portForwarder.forward(localPort: 8888, to: ip, remotePort: 8888)
                                        } catch {
                                            self.appendLog(service: id, message: "Port forwarding failed for port 8888: \(error.localizedDescription)")
                                        }
                                    }
                                }
                                let displayName = service.displayName
                                Task { await NotificationManager.postServiceStarted(displayName) }
                            } else if status == .error {
                                let service = self.services[idx]
                                let displayName = service.displayName
                                Task { await NotificationManager.postServiceError(displayName, error: "\(displayName) failed to start. Check Logs for details.") }
                            }
                        }
                    }
                },
                onLog: { [weak self] serviceId, line in
                    Task { @MainActor in
                        self?.appendLog(service: serviceId, message: line)
                    }
                },
                onPreparingProgress: { [weak self] serviceId, progress in
                    Task { @MainActor in
                        guard let self else { return }
                        if let idx = self.services.firstIndex(where: { $0.id == serviceId }) {
                            self.services[idx].preparingProgress = progress >= 1.0 ? nil : progress
                        }
                    }
                }
            )
        }

        healthChecker?.startMonitoring()
    }

    func stopAll() async throws {
        // Cancel any in-progress startup and wait for it to finish so that
        // containers mid-creation settle before we try to stop them.
        if let task = startTask {
            task.cancel()
            startTask = nil
            _ = try? await task.value
        }

        healthChecker?.stopMonitoring()
        if activeRuntime != .docker {
            await portForwarder.stopAll()
        }
        if let engine = containerEngine {
            services = try await engine.stopAll(
                services: services,
                onStatus: { [weak self] id, status, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if let idx = self.services.firstIndex(where: { $0.id == id }) {
                            self.services[idx].status = status
                        }
                    }
                },
                onLog: { [weak self] message in
                    Task { @MainActor in
                        self?.appendLog(service: "app", message: message)
                    }
                }
            )
        }
        await bridgeServer?.stop()
    }

    func openInBrowser() {
        if let url = URL(string: "http://localhost:\(config.backendPort)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the LiteLLM UI via the bridge's one-time auto-login URL.
    /// The bridge mints a short-lived token in-process (the browser cannot
    /// attach the bearer token), then we open the resulting URL.
    func openLiteLLMUI() {
        Task {
            guard let url = await bridgeServer?.makeLiteLLMLoginURL() else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func saveConfig() {
        storageManager?.saveConfig(config)
    }

    func resetData() async throws {
        try await stopAll()
        storageManager?.resetData()
    }

    func appendLog(service: String, message: String) {
        let cleaned = message.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        logs.append(LogEntry(timestamp: Date(), service: service, message: cleaned))
        // Ring-buffer semantics: drop the oldest entries once over the cap.
        if logs.count > maxLogEntries {
            logs.removeFirst(logs.count - maxLogEntries)
        }
    }

    func pullRequiredImages() async {
        let requiredServices = services.filter { service in
            if service.id == "litellm" && !config.deployLiteLLM { return false }
            if service.id == "hindsight" && !config.useHindsight { return false }
            return true
        }
        for service in requiredServices {
            imagePullProgress[service.id] = 0.0
        }
        for service in requiredServices {
            guard let imageRef = await containerEngine?.imageReference(for: service.id, config: config) else {
                continue
            }
            let serviceId = service.id
            do {
                try await containerEngine?.pullImage(name: imageRef) { [weak self] progress in
                    Task { @MainActor in
                        self?.imagePullProgress[serviceId] = progress
                    }
                }
                imagePullProgress[service.id] = 1.0
            } catch {
                appendLog(service: service.id, message: "Failed to pull image: \(error.localizedDescription)")
            }
        }
    }

    func completeFirstRun() {
        isFirstRun = false
        saveConfig()
        startAllInBackground()
    }

    // MARK: - Setup Services

    /// Starts only Postgres and LiteLLM during setup wizard, with port forwarding for LiteLLM.
    func startSetupServices() async throws {
        guard let engine = containerEngine else { return }

        // Refuse to start if keychain secrets are missing
        if keychainError != nil {
            throw AppError.keychainNotReady
        }

        var serviceIPs: [String: String] = [:]

        let logCallback: @Sendable (String, String) -> Void = { [weak self] serviceId, line in
            Task { @MainActor in
                self?.appendLog(service: serviceId, message: line)
            }
        }

        let progressCallback: @Sendable (String, Double) -> Void = { [weak self] serviceId, progress in
            Task { @MainActor in
                guard let self else { return }
                if let idx = self.services.firstIndex(where: { $0.id == serviceId }) {
                    self.services[idx].preparingProgress = progress >= 1.0 ? nil : progress
                }
            }
        }

        // Start Postgres first
        if let pgIdx = services.firstIndex(where: { $0.id == "postgres" }) {
            services[pgIdx] = try await engine.startService(
                services[pgIdx],
                config: config,
                serviceIPs: serviceIPs,
                onStatus: { [weak self] id, status, containerIP in
                    Task { @MainActor in
                        if let idx = self?.services.firstIndex(where: { $0.id == id }) {
                            self?.services[idx].status = status
                            if let containerIP {
                                self?.services[idx].containerIP = containerIP
                            }
                            if status == .error, let displayName = self?.services[idx].displayName {
                                Task { await NotificationManager.postServiceError(displayName, error: "\(displayName) failed to start. Check Logs for details.") }
                            }
                        }
                    }
                },
                onLog: logCallback,
                onPreparingProgress: progressCallback
            )
            if let ip = services[pgIdx].containerIP {
                serviceIPs["postgres"] = ip
            }
        }

        // Start LiteLLM with Postgres IP
        if let litellmIdx = services.firstIndex(where: { $0.id == "litellm" }) {
            services[litellmIdx] = try await engine.startService(
                services[litellmIdx],
                config: config,
                serviceIPs: serviceIPs,
                onStatus: { [weak self] id, status, containerIP in
                    Task { @MainActor in
                        if let idx = self?.services.firstIndex(where: { $0.id == id }) {
                            self?.services[idx].status = status
                            if let containerIP {
                                self?.services[idx].containerIP = containerIP
                            }
                            if status == .error, let displayName = self?.services[idx].displayName {
                                Task { await NotificationManager.postServiceError(displayName, error: "\(displayName) failed to start. Check Logs for details.") }
                            }
                        }
                    }
                },
                onLog: logCallback,
                onPreparingProgress: progressCallback
            )

            // Set up port forwarding for LiteLLM so localhost:{litellmPort} works (Apple only; Docker publishes natively)
            if activeRuntime != .docker, let ip = services[litellmIdx].containerIP {
                try await portForwarder.forward(localPort: config.litellmPort, to: ip, remotePort: 4000)
            }

            // Provision scoped service keys now that LiteLLM is healthy
            await engine.provisionServiceKeys(config: config)
        }
    }

    // MARK: - Model Fetching

    /// Model info returned from the /v1/models endpoint.
    struct ModelInfo: Identifiable {
        let id: String
        let mode: String
    }

    /// Fetches available models from the configured LLM provider.
    /// Returns (chatModels, embeddingModels). For litellm providers, models are filtered by mode.
    /// For openai_compatible providers, all models appear in both lists.
    /// For unknown providers, returns empty (caller should show free text fields).
    func fetchAvailableModels() async -> (chat: [ModelInfo], embedding: [ModelInfo]) {
        let providerType: ProviderType
        let baseURL: String
        let apiKey: String

        if config.deployLiteLLM {
            providerType = .litellm
            baseURL = "http://localhost:\(config.litellmPort)"
            apiKey = litellmMasterKeyDisplay
        } else {
            providerType = ProviderType(rawValue: config.llmProviderType) ?? .unknown
            baseURL = config.llmProviderBaseURL
            apiKey = config.llmProviderAPIKey
        }

        guard providerType != .unknown else { return ([], []) }

        switch providerType {
        case .litellm:
            return await fetchLiteLLMModels(baseURL: baseURL, apiKey: apiKey)
        case .openaiCompatible:
            return await fetchOpenAIModels(baseURL: baseURL, apiKey: apiKey)
        case .unknown:
            return ([], [])
        }
    }

    /// Fetches models from a LiteLLM /model/info endpoint, filtering by mode.
    private func fetchLiteLLMModels(baseURL: String, apiKey: String) async -> (chat: [ModelInfo], embedding: [ModelInfo]) {
        let strippedURL = baseURL.hasSuffix("/v1") ? String(baseURL.dropLast(3)) : baseURL
        guard let url = URL(string: "\(strippedURL)/model/info") else { return ([], []) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["data"] as? [[String: Any]] ?? []

            var chat: [ModelInfo] = []
            var embedding: [ModelInfo] = []

            for model in models {
                guard let name = model["model_name"] as? String else { continue }
                let modelInfo = model["model_info"] as? [String: Any]
                let mode = modelInfo?["mode"] as? String ?? ""
                let info = ModelInfo(id: name, mode: mode)
                // LiteLLM only sets `mode` on `model_info` when the user (or
                // provider metadata) explicitly tags it. Treat missing/unknown
                // modes as chat so models added via the LiteLLM UI without a
                // mode tag still appear in the picker. Embeddings are still
                // gated on an explicit `embedding` tag to avoid mis-listing
                // chat models in the embedding dropdown.
                switch mode {
                case "embedding": embedding.append(info)
                default: chat.append(info)
                }
            }
            return (chat, embedding)
        } catch {
            appendLog(service: "system", message: "Failed to fetch models: \(error.localizedDescription)")
            return ([], [])
        }
    }

    /// Fetches models from a standard OpenAI-compatible /models endpoint.
    /// Returns all models in both chat and embedding lists (no mode filtering available).
    private func fetchOpenAIModels(baseURL: String, apiKey: String) async -> (chat: [ModelInfo], embedding: [ModelInfo]) {
        guard let url = URL(string: "\(baseURL)/models") else { return ([], []) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["data"] as? [[String: Any]] ?? []

            let all = models.compactMap { model -> ModelInfo? in
                guard let id = model["id"] as? String else { return nil }
                return ModelInfo(id: id, mode: "")
            }
            return (all, all)
        } catch {
            appendLog(service: "system", message: "Failed to fetch models: \(error.localizedDescription)")
            return ([], [])
        }
    }

}

/// Errors that prevent the app from starting services.
enum AppError: Error, LocalizedError {
    case keychainNotReady
    case noRuntime

    var errorDescription: String? {
        switch self {
        case .keychainNotReady:
            return "Cannot start services: encryption keys could not be loaded from the macOS Keychain."
        case .noRuntime:
            return "Cannot start services: no container runtime available. Install Docker Desktop or upgrade to macOS 26 on Apple Silicon."
        }
    }
}

/// A single log entry from a container.
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let service: String
    let message: String
}
