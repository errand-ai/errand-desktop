import Foundation
import SwiftUI

/// Central app state shared across views. Manages services, config, and orchestration.
@MainActor
class AppState: ObservableObject {
    @Published var services: [ServiceInfo] = [
        ServiceInfo(id: "postgres", displayName: "PostgreSQL", port: 5432),
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
    private(set) var updateChecker = UpdateChecker()

    /// Overall status derived from service states.
    var appStatus: AppStatus {
        let running = services.filter { $0.status == .running }
        let starting = services.filter { $0.status == .starting }
        let errored = services.filter { $0.status == .error }

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

    func initialize() async {
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

        // Start services in dependency order
        try await containerEngine?.startAll(services: &services, config: config)

        // Run Alembic migrations after Postgres is healthy, before backend serves
        if let backendService = services.first(where: { $0.id == "backend" }),
           let containerId = backendService.containerId {
            let success = try await migrationRunner?.runAndReport(
                backendContainerId: containerId,
                onLog: { [weak self] service, message in
                    Task { @MainActor in
                        self?.appendLog(service: service, message: message)
                    }
                }
            ) ?? true

            if !success {
                // Migration failed — mark backend as error, do not proceed
                if let idx = services.firstIndex(where: { $0.id == "backend" }) {
                    services[idx].status = .error
                }
                migrationError = "Database migration failed. Check logs for details."
                return
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
        try? await liteLLMManager?.stop()
        try await containerEngine?.stopAll(services: &services)
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
            do {
                try await containerEngine?.pullImage(name: service.id)
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
