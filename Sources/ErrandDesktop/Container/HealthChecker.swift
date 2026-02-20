import Foundation

/// Monitors health of running services via TCP/HTTP checks.
@MainActor
class HealthChecker {
    private let appState: AppState
    private var monitoringTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
    }

    func startMonitoring() {
        // TODO: Implement in task 3.4
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
}
