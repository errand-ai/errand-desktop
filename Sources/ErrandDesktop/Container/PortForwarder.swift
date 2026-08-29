import Foundation
@preconcurrency import Network

/// Forwards TCP connections from localhost to container VM IPs.
/// Each forwarding rule listens on a local port and relays traffic
/// to the corresponding container IP and port.
///
/// An `actor` so all access to the `rules` array is serialized by the actor
/// executor. Network framework callbacks are delivered on a dedicated dispatch
/// queue; they touch only local/Sendable state, never `rules`.
actor PortForwarder {

    /// A single active forwarding rule.
    private struct Rule {
        let listener: NWListener
        let localPort: UInt16
        let remoteHost: String
        let remotePort: UInt16
    }

    private var rules: [Rule] = []

    /// Dedicated queue for Network framework callbacks (listeners/connections).
    /// Nonisolated so it can be handed to `NWListener`/`NWConnection` without
    /// crossing the actor boundary.
    private nonisolated let networkQueue = DispatchQueue(label: "sh.errand.port-forwarder")

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

        // Capture only Sendable values (not the whole Rule) in the @Sendable handler.
        let targetHost = remoteHost
        let targetPort = UInt16(remotePort)
        listener.newConnectionHandler = { [weak self] inbound in
            self?.handleConnection(inbound, remoteHost: targetHost, remotePort: targetPort)
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

        listener.start(queue: networkQueue)
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

    /// Relays a single inbound connection to `remoteHost:remotePort`.
    /// Nonisolated: it touches no actor state, only the Network transport.
    private nonisolated func handleConnection(_ inbound: NWConnection, remoteHost: String, remotePort: UInt16) {
        let outbound = NWConnection(
            host: NWEndpoint.Host(remoteHost),
            port: NWEndpoint.Port(integerLiteral: remotePort),
            using: .tcp
        )

        inbound.start(queue: networkQueue)
        outbound.start(queue: networkQueue)

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

