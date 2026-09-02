import Foundation
@preconcurrency import Network

/// Decides which peers the bridge server will serve.
///
/// The bridge socket binds all interfaces so containers can reach it, so this
/// policy is the control that keeps arbitrary hosts out. It is a plain value
/// type holding raw address bytes rather than `IPv4Address` so it is trivially
/// `Sendable` and directly testable.
struct PeerAddressPolicy: Sendable {

    /// The four bytes of the runtime's gateway address, or nil when the runtime
    /// exposes no numeric gateway (Docker names its gateway `host.docker.internal`).
    let gatewayBytes: [UInt8]?

    /// True when a numeric gateway is known and peers are matched against its /24.
    /// When false, the RFC 1918 fallback applies.
    var validatesAgainstGateway: Bool { gatewayBytes != nil }

    /// Builds a policy from a runtime-supplied gateway. A nil or non-numeric
    /// value (Docker) selects the RFC 1918 fallback.
    init(gatewayIP: String?) {
        if let gatewayIP, let address = IPv4Address(gatewayIP) {
            self.gatewayBytes = Array(address.rawValue)
        } else {
            self.gatewayBytes = nil
        }
    }

    /// Builds a policy directly from gateway bytes.
    init(gatewayBytes: [UInt8]?) {
        self.gatewayBytes = gatewayBytes
    }

    /// Whether a peer at `host` may be served.
    func allows(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return allowsIPv4(Array(address.rawValue))
        case .ipv6(let address):
            if address == IPv6Address("::1") { return true }
            let bytes = Array(address.rawValue)
            // IPv4-mapped IPv6 (::ffff:a.b.c.d): validate the embedded IPv4.
            // RFC 4291 requires the leading ten bytes to be zero as well as the
            // 0xffff marker. Matching on the marker alone would read a routable
            // address such as 2001:db8::ffff:c0a8:4003 as 192.168.64.3 and admit
            // a peer that is nowhere near the gateway subnet.
            if bytes.count == 16,
               bytes[0...9].allSatisfy({ $0 == 0 }),
               bytes[10] == 0xff, bytes[11] == 0xff {
                return allowsIPv4(Array(bytes[12...15]))
            }
            return false
        default:
            // Hostname endpoints (`.name`) never appear for accepted TCP peers.
            return false
        }
    }

    /// Whether a peer at the given 4-byte IPv4 address may be served: loopback
    /// always, then either the gateway's /24 or — with no numeric gateway — any
    /// RFC 1918 address.
    func allowsIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        if bytes[0] == 127 { return true } // loopback 127.0.0.0/8
        guard let gateway = gatewayBytes, gateway.count == 4 else {
            return Self.isPrivateIPv4(bytes)
        }
        return bytes[0] == gateway[0] && bytes[1] == gateway[1] && bytes[2] == gateway[2]
    }

    /// True for the RFC 1918 private ranges: 10/8, 172.16/12, 192.168/16.
    ///
    /// Used only when the runtime exposes no numeric gateway (Docker), where the
    /// container subnet is private but not known ahead of time. This blocks peers
    /// reaching us over a public/routable address; it does not isolate us from
    /// other hosts on the same private LAN, which remains the reason every API
    /// route also requires the bearer token.
    static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }
}

/// Single-use, short-lived tokens for the browser-facing `/litellm-login` page.
///
/// A value type: the `BridgeServer` actor owns one and provides the isolation.
/// `now` is a parameter rather than read internally so expiry is testable.
struct LoginTokenStore: Sendable {

    /// How long a minted token stays valid.
    let lifetime: TimeInterval

    private var tokens: [String: Date] = [:]

    init(lifetime: TimeInterval = 60) {
        self.lifetime = lifetime
    }

    /// Number of tokens currently held (including any not yet swept).
    var count: Int { tokens.count }

    /// Records a freshly generated token as valid from `now`.
    mutating func mint(_ token: String, now: Date = Date()) {
        tokens[token] = now
    }

    /// Validates and consumes a token. Returns false for a nil, unknown, already
    /// used, or expired token. Expired entries are swept on every call.
    mutating func consume(_ token: String?, now: Date = Date()) -> Bool {
        tokens = tokens.filter { now.timeIntervalSince($0.value) <= lifetime }
        guard let token, let created = tokens.removeValue(forKey: token) else {
            return false
        }
        return now.timeIntervalSince(created) <= lifetime
    }
}

/// Parsing and validation for `/containers/...` bridge routes.
enum ContainerRoute {

    /// Parses paths like `/containers/{id}` or `/containers/{id}/action`.
    /// Returns nil if the path is not a container route or the ID is invalid,
    /// which blocks path traversal and other unexpected characters.
    static func parse(_ path: String) -> (id: String, action: String?)? {
        let prefix = "/containers/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        guard !rest.isEmpty else { return nil }
        let parts = rest.split(separator: "/", maxSplits: 1)
        let id = String(parts[0])
        guard isValidID(id) else { return nil }
        let action = parts.count > 1 ? String(parts[1]) : nil
        return (id, action)
    }

    /// Validates a container ID against `^[a-zA-Z0-9_-]{1,128}$`.
    static func isValidID(_ id: String) -> Bool {
        guard (1...128).contains(id.count) else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
