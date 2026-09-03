import XCTest
import Synchronization
@testable import ErrandDesktop

/// Scriptable stand-in for the database and keychain.
private final class FakePostgresIO: PostgresCredentialIO {

    struct State: Sendable {
        /// Passwords the "database" currently accepts.
        var valid: Set<String> = []
        /// Passwords handed out by `generatePassword()`, in order.
        var generated: [String] = ["fresh1", "fresh2"]
        var rotateSucceeds = true
        var persistThrows = false
        /// Ordered log of side effects, for asserting sequencing.
        var calls: [String] = []
        var persisted: [String] = []
    }

    struct PersistFailure: Error {}

    let state = Mutex(State())

    init(valid: Set<String> = [], rotateSucceeds: Bool = true, persistThrows: Bool = false) {
        state.withLock {
            $0.valid = valid
            $0.rotateSucceeds = rotateSucceeds
            $0.persistThrows = persistThrows
        }
    }

    func authenticates(password: String) async -> Bool {
        state.withLock {
            $0.calls.append("probe(\(password))")
            return $0.valid.contains(password)
        }
    }

    func rotate(to password: String) async -> Bool {
        state.withLock {
            $0.calls.append("rotate(\(password))")
            guard $0.rotateSucceeds else { return false }
            // The database now accepts only the new password.
            $0.valid = [password]
            return true
        }
    }

    func persist(_ password: String) throws {
        try state.withLock {
            $0.calls.append("persist(\(password))")
            if $0.persistThrows { throw PersistFailure() }
            $0.persisted.append(password)
        }
    }

    func generatePassword() -> String {
        state.withLock { $0.generated.removeFirst() }
    }

    var calls: [String] { state.withLock { $0.calls } }
    var persisted: [String] { state.withLock { $0.persisted } }
}

final class PostgresCredentialReconcilerTests: XCTestCase {

    // MARK: Fresh installs

    func testStoredPasswordThatWorksIsKept() async {
        let io = FakePostgresIO(valid: ["stored-pw"])
        let result = await PostgresCredentialReconciler(io: io).reconcile(stored: "stored-pw")

        XCTAssertEqual(result.password, "stored-pw")
        XCTAssertEqual(result.outcome, .matchedStored)
        XCTAssertEqual(io.calls, ["probe(stored-pw)"], "a working password must not trigger a rotation")
    }

    // MARK: Upgrading installs

    func testDatabaseOnLegacyPasswordIsRotated() async {
        let io = FakePostgresIO(valid: [legacyPostgresPassword])
        let result = await PostgresCredentialReconciler(io: io).reconcile(stored: nil)

        XCTAssertEqual(result.outcome, .rotated)
        XCTAssertEqual(result.password, "fresh1")
        XCTAssertEqual(io.persisted, ["fresh1"])
    }

    /// An install that generated a password before this migration existed: the
    /// stored value never applied because PGDATA already existed.
    func testStoredPasswordThatFailsFallsBackToLegacy() async {
        let io = FakePostgresIO(valid: [legacyPostgresPassword])
        let result = await PostgresCredentialReconciler(io: io).reconcile(stored: "never-applied")

        XCTAssertEqual(result.outcome, .rotated)
        XCTAssertEqual(result.password, "fresh1")
        XCTAssertEqual(io.calls.first, "probe(never-applied)")
    }

    func testNewPasswordIsPersistedBeforeTheDatabaseIsChanged() async {
        let io = FakePostgresIO(valid: [legacyPostgresPassword])
        _ = await PostgresCredentialReconciler(io: io).reconcile(stored: nil)

        let persistIndex = io.calls.firstIndex(of: "persist(fresh1)")
        let rotateIndex = io.calls.firstIndex(of: "rotate(fresh1)")
        XCTAssertNotNil(persistIndex)
        XCTAssertNotNil(rotateIndex)
        XCTAssertLessThan(
            persistIndex!, rotateIndex!,
            "persisting after rotating would leave a database whose password is recorded nowhere"
        )
    }

    // MARK: Failure handling

    func testRotationFailureKeepsTheLegacyPasswordForThisRun() async {
        let io = FakePostgresIO(valid: [legacyPostgresPassword], rotateSucceeds: false)
        let result = await PostgresCredentialReconciler(io: io).reconcile(stored: nil)

        XCTAssertEqual(result.outcome, .rotationFailed)
        XCTAssertEqual(result.password, legacyPostgresPassword, "the database still has the legacy password")
        XCTAssertEqual(io.persisted, ["fresh1"], "the attempted password is recorded so the next launch can recover")
    }

    func testPersistFailureLeavesTheDatabaseUntouched() async {
        let io = FakePostgresIO(valid: [legacyPostgresPassword], persistThrows: true)
        let result = await PostgresCredentialReconciler(io: io).reconcile(stored: nil)

        XCTAssertEqual(result.outcome, .rotationFailed)
        XCTAssertEqual(result.password, legacyPostgresPassword)
        XCTAssertFalse(io.calls.contains { $0.hasPrefix("rotate(") },
                       "rotating without recording the password would be unrecoverable")
    }

    func testUnknownCredentialsAreReported() async {
        let io = FakePostgresIO(valid: [])
        let result = await PostgresCredentialReconciler(io: io).reconcile(stored: "stored-pw")

        XCTAssertEqual(result.outcome, .unknownCredentials)
        XCTAssertEqual(result.password, "stored-pw")
        XCTAssertFalse(io.calls.contains { $0.hasPrefix("rotate(") })
    }

    func testUnknownCredentialsWithNothingStored() async {
        let io = FakePostgresIO(valid: [])
        let result = await PostgresCredentialReconciler(io: io).reconcile(stored: nil)

        XCTAssertEqual(result.outcome, .unknownCredentials)
        XCTAssertEqual(result.password, legacyPostgresPassword)
    }

    /// The property the persist-then-rotate ordering exists to provide: a run
    /// interrupted between persisting and rotating recovers on the next launch.
    func testInterruptedRotationRecoversOnTheNextLaunch() async {
        let io = FakePostgresIO(valid: [legacyPostgresPassword], rotateSucceeds: false)
        let first = await PostgresCredentialReconciler(io: io).reconcile(stored: nil)
        XCTAssertEqual(first.outcome, .rotationFailed)

        // Next launch: the stored value is what the interrupted run persisted,
        // and rotation now works.
        io.state.withLock { $0.rotateSucceeds = true }
        let second = await PostgresCredentialReconciler(io: io).reconcile(stored: io.persisted.last)

        XCTAssertEqual(second.outcome, .rotated)
        XCTAssertEqual(second.password, "fresh2")
    }
}

final class ContainerPostgresCredentialIOTests: XCTestCase {

    func testShellSafetyRejectsAnythingButAlphanumerics() {
        XCTAssertTrue(ContainerPostgresCredentialIO.isShellSafe("postgres"))
        XCTAssertTrue(ContainerPostgresCredentialIO.isShellSafe("a1b2c3D4"))
        XCTAssertFalse(ContainerPostgresCredentialIO.isShellSafe(""))
        XCTAssertFalse(ContainerPostgresCredentialIO.isShellSafe("has'quote"))
        XCTAssertFalse(ContainerPostgresCredentialIO.isShellSafe("has space"))
        XCTAssertFalse(ContainerPostgresCredentialIO.isShellSafe("semi;colon"))
        XCTAssertFalse(ContainerPostgresCredentialIO.isShellSafe("$(whoami)"))
    }

    func testUnsafePasswordIsNeverSentToTheContainer() async {
        let io = ContainerPostgresCredentialIO(containerId: "c") { _, _ in
            XCTFail("an unsafe password must not reach the container")
            return (0, "", "")
        }
        let authenticated = await io.authenticates(password: "bad'; DROP")
        let rotated = await io.rotate(to: "bad'; DROP")
        XCTAssertFalse(authenticated)
        XCTAssertFalse(rotated)
    }
}
