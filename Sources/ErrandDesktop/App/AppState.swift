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

    private var containerEngine: ContainerEngine?
    private var storageManager: StorageManager?
    private var bridgeServer: BridgeServer?
    private var healthChecker: HealthChecker?

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

        if config.litellmEnabled {
            addLiteLLMService()
        }
    }

    func startAll() async throws {
        // Implemented by ContainerEngine — starts services in dependency order
        try await containerEngine?.startAll(services: &services, config: config)
        healthChecker?.startMonitoring()
    }

    func stopAll() async throws {
        healthChecker?.stopMonitoring()
        try await containerEngine?.stopAll(services: &services)
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
