import Foundation
import SwiftUI

/// Central app state shared across views. Manages services, config, and orchestration.
@MainActor
class AppState: ObservableObject {
    @Published var services: [ServiceInfo] = [
        ServiceInfo(id: "postgres", displayName: "PostgreSQL", port: 5432),
        ServiceInfo(id: "migrate", displayName: "Migrate", isEphemeral: true),
        ServiceInfo(id: "valkey", displayName: "Valkey", port: 6379),
        ServiceInfo(id: "backend", displayName: "Backend", port: 8000),
        ServiceInfo(id: "worker", displayName: "Worker"),
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

    /// Overall status derived from service states.
    var appStatus: AppStatus {
        // Exclude ephemeral services (like migrate) from status calculation
        let longRunning = services.filter { !$0.isEphemeral }
        let running = longRunning.filter { $0.status == .running }
        let starting = longRunning.filter { $0.status == .starting || $0.status == .pulling }
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

        // Load persisted LiteLLM providers
        await liteLLMManager?.loadProviders()

        if config.litellmEnabled {
            addLiteLLMService()
        }

        // Start checking for updates
        updateChecker.startPeriodicChecks()
    }

    func startAll() async throws {
        migrationError = nil

        // Start the bridge API server so the worker can create task-runner containers
        try await bridgeServer?.start()

        // Start services in dependency order with UI progress updates
        if let engine = containerEngine {
            services = try await engine.startAll(
                services: services,
                config: config,
                onStatus: { [weak self] id, status in
                    Task { @MainActor in
                        guard let self else { return }
                        if let idx = self.services.firstIndex(where: { $0.id == id }) {
                            self.services[idx].status = status
                        }
                    }
                },
                onLog: { [weak self] serviceId, line in
                    Task { @MainActor in
                        self?.appendLog(service: serviceId, message: line)
                    }
                }
            )
        }

        // Set up port forwarding from localhost to container VMs
        portForwarder.stopAll()
        for service in services {
            guard let port = service.port, let ip = service.containerIP else { continue }
            do {
                try portForwarder.forward(localPort: port, to: ip, remotePort: port)
            } catch {
                appendLog(service: service.id, message: "Port forwarding failed for port \(port): \(error.localizedDescription)")
            }
        }

        // Start LiteLLM if enabled
        if config.litellmEnabled {
            do {
                try await liteLLMManager?.start(port: config.litellmPort)
                if let idx = services.firstIndex(where: { $0.id == "litellm" }) {
                    services[idx].status = .running
                }
            } catch {
                if let idx = services.firstIndex(where: { $0.id == "litellm" }) {
                    services[idx].status = .error
                }
                appendLog(service: "litellm", message: "Failed to start: \(error.localizedDescription)")
            }
        }

        healthChecker?.startMonitoring()
    }

    func stopAll() async throws {
        healthChecker?.stopMonitoring()
        portForwarder.stopAll()
        try? await liteLLMManager?.stop()
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

    private func addLiteLLMService() {
        if !services.contains(where: { $0.id == "litellm" }) {
            services.insert(
                ServiceInfo(id: "litellm", displayName: "LiteLLM", port: config.litellmPort),
                at: services.count  // After worker
            )
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
