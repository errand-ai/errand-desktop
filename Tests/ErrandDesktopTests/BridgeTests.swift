import XCTest
import Network
@testable import ErrandDesktop

// MARK: - Peer Address Policy (bridge source-address validation)

/// Apple runtime: a numeric vmnet gateway is known, so only loopback and the
/// gateway's /24 are served.
final class PeerAddressPolicyGatewayTests: XCTestCase {

    /// Mirrors a typical vmnet gateway (192.168.64.1).
    private let policy = PeerAddressPolicy(gatewayIP: "192.168.64.1")

    private func allows(_ ip: String) -> Bool {
        policy.allows(.ipv4(IPv4Address(ip)!))
    }

    func testNumericGatewayEnablesGatewayValidation() {
        XCTAssertTrue(policy.validatesAgainstGateway)
    }

    func testLoopbackIsAllowed() {
        XCTAssertTrue(allows("127.0.0.1"))
        XCTAssertTrue(allows("127.5.5.5")) // all of 127.0.0.0/8
    }

    func testPeerOnGatewaySubnetIsAllowed() {
        // Containers connect from their own subnet-peer IP, not the gateway itself.
        XCTAssertTrue(allows("192.168.64.3"))
        XCTAssertTrue(allows("192.168.64.1"))
    }

    /// The property task 7.2 checks by hand: a host on a different private
    /// subnet (an ordinary LAN device) is not served.
    func testPeerOnDifferentPrivateSubnetIsRejected() {
        XCTAssertFalse(allows("192.168.1.50"))
        XCTAssertFalse(allows("10.0.0.9"))
    }

    func testPublicAddressIsRejected() {
        XCTAssertFalse(allows("8.8.8.8"))
    }

    func testIPv6LoopbackIsAllowed() {
        XCTAssertTrue(policy.allows(.ipv6(IPv6Address("::1")!)))
    }

    func testIPv4MappedIPv6IsValidatedAgainstEmbeddedAddress() {
        XCTAssertTrue(policy.allows(.ipv6(IPv6Address("::ffff:192.168.64.3")!)))
        XCTAssertFalse(policy.allows(.ipv6(IPv6Address("::ffff:8.8.8.8")!)))
    }

    func testOtherIPv6AddressesAreRejected() {
        XCTAssertFalse(policy.allows(.ipv6(IPv6Address("2001:db8::1")!)))
    }

    /// A routable IPv6 address can carry the 0xffff marker in bytes 10-11 and an
    /// allowed-looking IPv4 in its last four bytes. Only a genuine IPv4-mapped
    /// address (RFC 4291: first ten bytes zero) may be unwrapped — otherwise any
    /// IPv6 peer could pose as one on the gateway subnet.
    func testRoutableIPv6CarryingAnAllowedIPv4SuffixIsRejected() {
        // 2001:db8::ffff:c0a8:4003 ends in 192.168.64.3, which is on the gateway /24.
        XCTAssertFalse(policy.allows(.ipv6(IPv6Address("2001:db8::ffff:c0a8:4003")!)))
        // ::ffff:127.0.0.1 embedded in a routable prefix must not read as loopback.
        XCTAssertFalse(policy.allows(.ipv6(IPv6Address("2001:db8::ffff:7f00:1")!)))
    }

    func testGenuineIPv4MappedAddressIsStillAccepted() {
        XCTAssertTrue(policy.allows(.ipv6(IPv6Address("::ffff:192.168.64.3")!)))
        XCTAssertTrue(policy.allows(.ipv6(IPv6Address("::ffff:127.0.0.1")!)))
    }

    /// Deprecated IPv4-compatible form (::a.b.c.d) lacks the 0xffff marker and is
    /// not unwrapped.
    func testIPv4CompatibleIPv6IsRejected() {
        XCTAssertFalse(policy.allows(.ipv6(IPv6Address("::192.168.64.3")!)))
    }

    func testHostnamePeerIsRejected() {
        XCTAssertFalse(policy.allows(.name("evil.example.com", nil)))
    }

    func testMalformedByteCountIsRejected() {
        XCTAssertFalse(policy.allowsIPv4([192, 168, 64]))
        XCTAssertFalse(policy.allowsIPv4([]))
    }
}

/// Docker runtime: the gateway is the name `host.docker.internal`, so there is
/// no numeric gateway and the RFC 1918 fallback applies.
final class PeerAddressPolicyPrivateFallbackTests: XCTestCase {

    private let policy = PeerAddressPolicy(gatewayIP: "host.docker.internal")

    private func allows(_ ip: String) -> Bool {
        policy.allows(.ipv4(IPv4Address(ip)!))
    }

    func testNonNumericGatewayDisablesGatewayValidation() {
        XCTAssertFalse(policy.validatesAgainstGateway)
        XCTAssertFalse(PeerAddressPolicy(gatewayIP: nil).validatesAgainstGateway)
    }

    func testLoopbackIsAllowed() {
        XCTAssertTrue(allows("127.0.0.1"))
    }

    func testDockerBridgeSubnetIsAllowed() {
        XCTAssertTrue(allows("172.17.0.2"))
        XCTAssertTrue(allows("10.1.2.3"))
    }

    /// The case that cannot be reproduced by hand on a developer machine: a peer
    /// reaching us over a routable address is refused.
    func testPublicAddressIsRejected() {
        XCTAssertFalse(allows("8.8.8.8"))
        XCTAssertFalse(allows("203.0.113.7"))
    }

    /// Documents the accepted limitation of the fallback: an ordinary LAN host
    /// is inside RFC 1918 and is admitted, so the bearer token remains the
    /// primary control under Docker.
    func testOrdinaryLANHostIsAdmittedByTheFallback() {
        XCTAssertTrue(allows("192.168.1.50"))
    }

    /// Same bypass, checked under the RFC 1918 fallback: 10.0.0.1 embedded in a
    /// routable IPv6 address must not be unwrapped.
    func testRoutableIPv6CarryingAPrivateIPv4SuffixIsRejected() {
        XCTAssertFalse(policy.allows(.ipv6(IPv6Address("2001:db8::ffff:0a00:1")!)))
        XCTAssertTrue(policy.allows(.ipv6(IPv6Address("::ffff:10.0.0.1")!)))
    }

    func test172RangeBoundaries() {
        XCTAssertFalse(allows("172.15.255.254")) // just below 172.16/12
        XCTAssertTrue(allows("172.16.0.1"))
        XCTAssertTrue(allows("172.31.255.254"))
        XCTAssertFalse(allows("172.32.0.1"))     // just above 172.16/12
    }
}

// MARK: - One-Time Login Tokens (/litellm-login)

final class LoginTokenStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFreshTokenIsAccepted() {
        var store = LoginTokenStore(lifetime: 60)
        store.mint("abc", now: now)
        XCTAssertTrue(store.consume("abc", now: now))
    }

    /// The property task 7.3 checks by hand: no token, no page.
    func testMissingOrUnknownTokenIsRejected() {
        var store = LoginTokenStore(lifetime: 60)
        store.mint("abc", now: now)
        XCTAssertFalse(store.consume(nil, now: now))
        XCTAssertFalse(store.consume("", now: now))
        XCTAssertFalse(store.consume("bogus", now: now))
    }

    func testTokenIsSingleUse() {
        var store = LoginTokenStore(lifetime: 60)
        store.mint("abc", now: now)
        XCTAssertTrue(store.consume("abc", now: now))
        XCTAssertFalse(store.consume("abc", now: now), "replaying a consumed token must fail")
    }

    func testTokenExpiresAfterLifetime() {
        var store = LoginTokenStore(lifetime: 60)
        store.mint("abc", now: now)
        XCTAssertFalse(store.consume("abc", now: now.addingTimeInterval(61)))
    }

    func testTokenIsValidUpToAndIncludingTheLifetimeBoundary() {
        var store = LoginTokenStore(lifetime: 60)
        store.mint("abc", now: now)
        XCTAssertTrue(store.consume("abc", now: now.addingTimeInterval(60)))
    }

    func testExpirySweepLeavesOtherValidTokensIntact() {
        var store = LoginTokenStore(lifetime: 60)
        store.mint("old", now: now)
        store.mint("new", now: now.addingTimeInterval(50))

        // At +70s "old" has expired but "new" (minted at +50) has not.
        XCTAssertFalse(store.consume("old", now: now.addingTimeInterval(70)))
        XCTAssertTrue(store.consume("new", now: now.addingTimeInterval(70)))
    }

    func testConsumingSweepsExpiredTokensFromStorage() {
        var store = LoginTokenStore(lifetime: 60)
        store.mint("a", now: now)
        store.mint("b", now: now)
        XCTAssertEqual(store.count, 2)

        _ = store.consume("missing", now: now.addingTimeInterval(61))
        XCTAssertEqual(store.count, 0, "expired tokens must not accumulate")
    }
}

// MARK: - Container Route Parsing

final class ContainerRouteTests: XCTestCase {

    func testValidIDIsParsed() {
        let route = ContainerRoute.parse("/containers/task-abc_123")
        XCTAssertEqual(route?.id, "task-abc_123")
        XCTAssertNil(route?.action)
    }

    func testActionIsParsed() {
        let route = ContainerRoute.parse("/containers/task-abc/status")
        XCTAssertEqual(route?.id, "task-abc")
        XCTAssertEqual(route?.action, "status")
    }

    func testPathTraversalIsRejected() {
        XCTAssertNil(ContainerRoute.parse("/containers/../etc/passwd"))
        XCTAssertNil(ContainerRoute.parse("/containers/.."))
    }

    func testDisallowedCharactersAreRejected() {
        XCTAssertNil(ContainerRoute.parse("/containers/abc.def"))
        XCTAssertNil(ContainerRoute.parse("/containers/abc%2F"))
        XCTAssertNil(ContainerRoute.parse("/containers/abc def"))
        XCTAssertNil(ContainerRoute.parse("/containers/abc$"))
    }

    func testNonContainerPathsAreNotRoutes() {
        XCTAssertNil(ContainerRoute.parse("/litellm-login"))
        XCTAssertNil(ContainerRoute.parse("/containers/"))
        XCTAssertNil(ContainerRoute.parse("/containers"))
    }

    func testIDLengthBounds() {
        XCTAssertTrue(ContainerRoute.isValidID(String(repeating: "a", count: 128)))
        XCTAssertFalse(ContainerRoute.isValidID(String(repeating: "a", count: 129)))
        XCTAssertFalse(ContainerRoute.isValidID(""))
    }
}

// MARK: - HTTP Request Parsing

final class HTTPRequestParsingTests: XCTestCase {

    private func data(_ raw: String) -> Data {
        raw.replacingOccurrences(of: "\n", with: "\r\n").data(using: .utf8)!
    }

    func testQueryIsSplitFromPathAndDecoded() throws {
        let request = try XCTUnwrap(
            HTTPRequest.parse(from: data("GET /litellm-login?token=a%20b&x=1 HTTP/1.1\nHost: localhost\n\n"))
        )
        XCTAssertEqual(request.path, "/litellm-login")
        XCTAssertEqual(request.queryValue("token"), "a b")
        XCTAssertEqual(request.queryValue("x"), "1")
        XCTAssertNil(request.queryValue("missing"))
    }

    func testQueryValueIsNilWhenNoQueryString() throws {
        let request = try XCTUnwrap(
            HTTPRequest.parse(from: data("GET /litellm-login HTTP/1.1\nHost: localhost\n\n"))
        )
        XCTAssertNil(request.queryValue("token"))
    }

    func testBodyIsParsed() throws {
        let request = try XCTUnwrap(
            HTTPRequest.parse(from: data("POST /containers HTTP/1.1\nContent-Length: 2\n\n{}"))
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "{}")
    }

    func testIncompleteRequestReturnsNil() throws {
        XCTAssertNil(try HTTPRequest.parse(from: data("GET /containers HTTP/1.1\nHost: local")))
    }

    func testOversizedContentLengthThrows() {
        let raw = data("POST /containers HTTP/1.1\nContent-Length: \(maxBodyBytes + 1)\n\n")
        XCTAssertThrowsError(try HTTPRequest.parse(from: raw)) { error in
            XCTAssertEqual(error as? HTTPParseError, .bodyTooLarge)
        }
    }

    /// At the limit the parser must not throw; it simply waits for the body.
    func testContentLengthAtLimitIsAccepted() throws {
        let raw = data("POST /containers HTTP/1.1\nContent-Length: \(maxBodyBytes)\n\n")
        XCTAssertNil(try HTTPRequest.parse(from: raw))
    }
}
