import Foundation
@preconcurrency import Network

/// Monitors health of running services via TCP/HTTP checks.
@MainActor
class HealthChecker {
    private let appState: AppState
    private let containerEngine: ContainerEngine
    private var monitoringTask: Task<Void, Never>?

    private let checkInterval: TimeInterval = 10
    private let maxFailures = 3

    init(appState: AppState, containerEngine: ContainerEngine) {
        self.appState = appState
        self.containerEngine = containerEngine
    }

    func startMonitoring() {
        stopMonitoring()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.checkAll()
                try? await Task.sleep(for: .seconds(self.checkInterval))
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // MARK: - Check All Services

    private func checkAll() async {
        for i in appState.services.indices {
            let service = appState.services[i]
            guard service.status == .running, !service.isEphemeral else { continue }

            // Fast path: if the container process has exited, mark it immediately
            if await containerEngine.hasExited(serviceId: service.id) {
                appState.services[i].status = .error
                appState.appendLog(service: service.id, message: "\(service.displayName) container exited unexpectedly")
                continue
            }

            let healthy: Bool
            switch service.id {
            case "postgres":
                healthy = await tcpCheck(host: service.containerIP ?? "127.0.0.1", port: 5432)
            case "valkey":
                healthy = await tcpCheck(host: service.containerIP ?? "127.0.0.1", port: 6379)
            case "backend":
                healthy = await httpCheck(host: service.containerIP ?? "127.0.0.1", port: 8000, path: "/health")
            case "litellm":
                healthy = await httpCheck(host: service.containerIP ?? "127.0.0.1", port: 4000, path: "/health/liveliness")
            case "hindsight":
                healthy = await httpCheck(host: service.containerIP ?? "127.0.0.1", port: 8888, path: "/health")
            default:
                continue
            }

            if healthy {
                appState.services[i].healthCheckFailures = 0
            } else {
                appState.services[i].healthCheckFailures += 1
                if appState.services[i].healthCheckFailures >= maxFailures {
                    appState.services[i].status = .error
                    appState.appendLog(service: service.id, message: "\(service.displayName) failed \(maxFailures) consecutive health checks")
                }
            }
        }
    }

    // MARK: - TCP Health Check

    /// Opens a TCP connection and considers the service healthy if the connection succeeds.
    private func tcpCheck(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let queue = DispatchQueue(label: "health-tcp-\(host):\(port)")
            nonisolated(unsafe) var resumed = false

            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Timeout after 5 seconds
            queue.asyncAfter(deadline: .now() + 5) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - HTTP Health Check

    /// Performs an HTTP GET and considers the service healthy on a 2xx response.
    private func httpCheck(host: String, port: Int, path: String) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

}
