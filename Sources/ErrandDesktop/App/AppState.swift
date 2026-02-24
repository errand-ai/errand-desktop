import Foundation
import SwiftUI

/// Central app state shared across views. Manages services, config, and orchestration.
@MainActor
class AppState: ObservableObject {
    @Published var services: [ServiceInfo] = [
        ServiceInfo(id: "postgres", displayName: "PostgreSQL", port: 5432),
        ServiceInfo(id: "valkey", displayName: "Valkey", port: 6379),
        ServiceInfo(id: "migrate", displayName: "Migrate", isEphemeral: true),
        ServiceInfo(id: "litellm", displayName: "LiteLLM", port: 4000),
        ServiceInfo(id: "hindsight", displayName: "Hindsight", port: 8081, containerPort: 8888),
        ServiceInfo(id: "backend", displayName: "Errand Service", port: 8000),
        ServiceInfo(id: "worker", displayName: "Errand Agent"),
    ]

    @Published var config: AppConfig = AppConfig()
    @Published var isFirstRun: Bool = false
    @Published var logs: [LogEntry] = []
    @Published var selectedLogService: String? = nil
    @Published var migrationError: String?
    @Published var imagePullProgress: [String: Double] = [:]

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
        healthChecker = HealthChecker(appState: self)
        liteLLMManager = LiteLLMManager(containerEngine: containerEngine!)
        migrationRunner = MigrationRunner(containerEngine: containerEngine!)

        // Pass bridge API credentials to ContainerEngine so it can inject them into the worker
        if let token = await bridgeServer?.authToken {
            await containerEngine?.setBridgeCredentials(token: token, port: 9876)
        }

        // Get or create the credential encryption key from the macOS Keychain
        do {
            let encKey = try KeychainManager.getOrCreate(account: "credential-encryption-key")
            await containerEngine?.setCredentialEncryptionKey(encKey)
        } catch {
            appendLog(service: "system", message: "Failed to load encryption key from Keychain: \(error.localizedDescription)")
        }

        // Get or create the LiteLLM master key from the macOS Keychain (sk-<18 alphanumeric> format)
        do {
            let masterKey = try KeychainManager.getOrCreateLiteLLMKey()
            await containerEngine?.setLiteLLMMasterKey(masterKey)
        } catch {
            appendLog(service: "system", message: "Failed to load LiteLLM master key from Keychain: \(error.localizedDescription)")
        }

        // Load persisted LiteLLM providers
        await liteLLMManager?.loadProviders()

        // Start checking for updates
        updateChecker.startPeriodicChecks()
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

        // Start the bridge API server so the worker can create task-runner containers
        try await bridgeServer?.start()

        // Clear existing port forwards before starting fresh
        portForwarder.stopAll()

        // Start services in dependency order with UI progress updates.
        // Port forwarding is set up incrementally as each service becomes running,
        // so earlier services are reachable while later ones are still starting.
        if let engine = containerEngine {
            services = try await engine.startAll(
                services: services,
                config: config,
                onStatus: { [weak self] id, status in
                    Task { @MainActor in
                        guard let self else { return }
                        if let idx = self.services.firstIndex(where: { $0.id == id }) {
                            self.services[idx].status = status

                            // Set up port forwarding as soon as the service is running
                            if status == .running {
                                let service = self.services[idx]
                                if let port = service.port, let ip = service.containerIP {
                                    let remotePort = service.containerPort ?? port
                                    do {
                                        try self.portForwarder.forward(localPort: port, to: ip, remotePort: remotePort)
                                    } catch {
                                        self.appendLog(service: id, message: "Port forwarding failed for port \(port): \(error.localizedDescription)")
                                    }
                                }
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
        // Cancel any in-progress startup first
        startTask?.cancel()
        startTask = nil

        healthChecker?.stopMonitoring()
        portForwarder.stopAll()
        if let engine = containerEngine {
            services = try await engine.stopAll(services: services)
        }
        await bridgeServer?.stop()
    }

    func openInBrowser() {
        if let url = URL(string: "http://localhost:\(config.backendPort)") {
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
        logs.append(LogEntry(timestamp: Date(), service: service, message: message))
    }

    func pullRequiredImages() async {
        for service in services {
            imagePullProgress[service.id] = 0.0
        }
        for service in services {
            guard let imageRef = await containerEngine?.imageReference(for: service.id, config: config) else {
                continue
            }
            do {
                try await containerEngine?.pullImage(name: imageRef)
                imagePullProgress[service.id] = 1.0
            } catch {
                appendLog(service: service.id, message: "Failed to pull image: \(error.localizedDescription)")
            }
        }
    }

    func completeFirstRun() {
        isFirstRun = false
        saveConfig()
    }

    // MARK: - Setup Services

    /// Starts only Postgres and LiteLLM during setup wizard, with port forwarding for LiteLLM.
    func startSetupServices() async throws {
        guard let engine = containerEngine else { return }

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
                onStatus: { [weak self] id, status in
                    Task { @MainActor in
                        if let idx = self?.services.firstIndex(where: { $0.id == id }) {
                            self?.services[idx].status = status
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
                onStatus: { [weak self] id, status in
                    Task { @MainActor in
                        if let idx = self?.services.firstIndex(where: { $0.id == id }) {
                            self?.services[idx].status = status
                        }
                    }
                },
                onLog: logCallback,
                onPreparingProgress: progressCallback
            )

            // Set up port forwarding for LiteLLM so localhost:{litellmPort} works
            if let ip = services[litellmIdx].containerIP {
                try portForwarder.forward(localPort: config.litellmPort, to: ip, remotePort: 4000)
            }
        }
    }

    // MARK: - Model Fetching

    /// Model info returned from the /v1/models endpoint.
    struct ModelInfo: Identifiable {
        let id: String
        let mode: String
    }

    /// Fetches available models from the LLM base URL.
    /// Returns (chatModels, embeddingModels) filtered by mode.
    func fetchAvailableModels() async -> (chat: [ModelInfo], embedding: [ModelInfo]) {
        let baseURL: String
        let apiKey: String

        if config.useLiteLLM {
            baseURL = "http://localhost:\(config.litellmPort)/v1"
            do {
                apiKey = try KeychainManager.getOrCreateLiteLLMKey()
            } catch {
                appendLog(service: "system", message: "Failed to get LiteLLM key: \(error.localizedDescription)")
                return ([], [])
            }
        } else {
            baseURL = config.openaiBaseURL
            apiKey = config.openaiAPIKey
        }

        // Use /model/info which includes the mode field (chat, embedding)
        let infoBaseURL = config.useLiteLLM
            ? "http://localhost:\(config.litellmPort)"
            : baseURL
        guard let url = URL(string: "\(infoBaseURL)/model/info") else { return ([], []) }

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
                switch mode {
                case "chat":
                    chat.append(info)
                case "embedding":
                    embedding.append(info)
                default:
                    break
                }
            }

            return (chat, embedding)
        } catch {
            appendLog(service: "system", message: "Failed to fetch models: \(error.localizedDescription)")
            return ([], [])
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
