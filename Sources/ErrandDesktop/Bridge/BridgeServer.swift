import Foundation

/// Local HTTP server exposing the container bridge API for the worker.
/// Binds to localhost only, authenticates via bearer token.
actor BridgeServer {
    private let containerEngine: ContainerEngine

    init(containerEngine: ContainerEngine) {
        self.containerEngine = containerEngine
    }

    // TODO: Implement in tasks 5.1-5.7
}
