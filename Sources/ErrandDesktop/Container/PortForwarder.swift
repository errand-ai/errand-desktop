import Foundation
import Network

/// Forwards TCP connections from localhost to container VM IPs.
/// Each forwarding rule listens on a local port and relays traffic
/// to the corresponding container IP and port.
final class PortForwarder: @unchecked Sendable {

    /// A single active forwarding rule.
    private struct Rule {
        let listener: NWListener
        let localPort: UInt16
        let remoteHost: String
        let remotePort: UInt16
    }

    private var rules: [Rule] = []
    private let queue = DispatchQueue(label: "sh.errand.port-forwarder", attributes: .concurrent)

    /// Starts forwarding `localPort` on localhost to `remoteHost:remotePort`.
    func forward(localPort: Int, to remoteHost: String, remotePort: Int) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(integerLiteral: UInt16(localPort))
        )

        let listener = try NWListener(using: params)

        let rule = Rule(
            listener: listener,
            localPort: UInt16(localPort),
            remoteHost: remoteHost,
            remotePort: UInt16(remotePort)
        )

        listener.newConnectionHandler = { [weak self] inbound in
            self?.handleConnection(inbound, rule: rule)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                debugLog("[PortForwarder] Listening on localhost:\(localPort) → \(remoteHost):\(remotePort)")
            case .failed(let error):
                debugLog("[PortForwarder] Listener failed on port \(localPort): \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
        rules.append(rule)
    }

    /// Stops all port forwarding listeners.
    func stopAll() {
        for rule in rules {
            rule.listener.cancel()
        }
        rules.removeAll()
        debugLog("[PortForwarder] All port forwarding stopped")
    }

    // MARK: - Private

    private func handleConnection(_ inbound: NWConnection, rule: Rule) {
        let outbound = NWConnection(
            host: NWEndpoint.Host(rule.remoteHost),
            port: NWEndpoint.Port(integerLiteral: rule.remotePort),
            using: .tcp
        )

        inbound.start(queue: queue)
        outbound.start(queue: queue)

        outbound.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Both ends connected — start relaying
                Self.relay(from: inbound, to: outbound)
                Self.relay(from: outbound, to: inbound)
            case .failed, .cancelled:
                inbound.cancel()
            default:
                break
            }
        }

        inbound.stateUpdateHandler = { state in
            if case .failed = state { outbound.cancel() }
            if case .cancelled = state { outbound.cancel() }
        }
    }

    /// Reads from `source` and writes to `destination` until EOF or error.
    private static func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        source.cancel()
                        destination.cancel()
                    } else {
                        relay(from: source, to: destination)
                    }
                })
            }
            if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    destination.cancel()
                })
                source.cancel()
            }
        }
    }
}

/// Debug log helper (defined in ContainerEngine.swift, referenced here).
/// Uses the same /tmp/errand-debug.log file.
private func debugLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let logPath = "/tmp/errand-debug.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}
