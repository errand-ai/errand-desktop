import Foundation

/// The password every install used before credentials were generated per-install.
/// A data directory created by an older build was initdb'd with this value, and
/// `POSTGRES_PASSWORD` is ignored once `PGDATA` exists — so upgrading installs
/// must discover this rather than assume the stored password works.
let legacyPostgresPassword = "postgres"

/// What reconciling the stored password against the live database concluded.
enum PostgresCredentialOutcome: String, Sendable {
    /// The stored password authenticates; nothing to do (the fresh-install path).
    case matchedStored
    /// The database was on the legacy password and has been rotated to a fresh one.
    case rotated
    /// The database is still on the legacy password: rotation could not be
    /// completed, and will be retried on the next launch.
    case rotationFailed
    /// Neither the stored nor the legacy password authenticates. The caller
    /// should surface this rather than let dependent services fail obscurely.
    case unknownCredentials
}

/// The side effects reconciliation needs, so the decision logic can be tested
/// without a running database.
protocol PostgresCredentialIO: Sendable {
    /// Whether `password` authenticates against the running database.
    func authenticates(password: String) async -> Bool
    /// Changes the database's password. Returns false if the change did not apply.
    func rotate(to password: String) async -> Bool
    /// Records `password` as the one the database is expected to use.
    func persist(_ password: String) throws
    /// Generates a fresh random password.
    func generatePassword() -> String
}

/// Reconciles the password we have stored with the one the database actually has.
///
/// Ordering is deliberate: the new password is persisted *before* the database is
/// changed. Every interruption then leaves a state the next launch can recover:
///
/// - persisted, rotation never ran → stored fails, legacy succeeds, retry rotation
/// - persisted, rotation applied, crash before returning → stored succeeds
/// - persist failed → nothing changed, the database keeps the legacy password
///
/// Persisting after rotating instead would leave a database whose password is
/// recorded nowhere, which is unrecoverable without wiping the data directory.
struct PostgresCredentialReconciler: Sendable {

    let io: any PostgresCredentialIO

    init(io: any PostgresCredentialIO) {
        self.io = io
    }

    /// Determines the password dependent services should use, migrating the
    /// database off the legacy credential when it is still on it.
    func reconcile(stored: String?) async -> (password: String, outcome: PostgresCredentialOutcome) {
        if let stored, await io.authenticates(password: stored) {
            return (stored, .matchedStored)
        }

        // Either nothing was stored (an install predating generated credentials)
        // or what we stored does not work (an interrupted earlier rotation).
        guard await io.authenticates(password: legacyPostgresPassword) else {
            return (stored ?? legacyPostgresPassword, .unknownCredentials)
        }

        let fresh = io.generatePassword()
        do {
            try io.persist(fresh)
        } catch {
            // Could not record the new password, so do not change the database:
            // rotating now would strand it with a password stored nowhere.
            return (legacyPostgresPassword, .rotationFailed)
        }

        guard await io.rotate(to: fresh) else {
            // The database still has the legacy password. Use it for this run;
            // the stored value now disagrees, which the next launch resolves by
            // probing legacy again and retrying.
            return (legacyPostgresPassword, .rotationFailed)
        }

        return (fresh, .rotated)
    }
}

/// Runs the probes and the rotation as `psql` invocations inside the Postgres
/// container, so no client tooling is needed on the host.
struct ContainerPostgresCredentialIO: PostgresCredentialIO {

    let containerId: String
    let exec: @Sendable (String, [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String)

    /// Probes over TCP to 127.0.0.1 rather than the container's unix socket: the
    /// socket is configured for trust auth and would accept any password, which
    /// would make every probe succeed and defeat the whole check.
    func authenticates(password: String) async -> Bool {
        guard Self.isShellSafe(password) else { return false }
        return await run("PGPASSWORD='\(password)' psql -h 127.0.0.1 -U postgres -d postgres -tAc 'select 1'")
    }

    /// Rotates over the unix socket, which *does* use trust auth — that is what
    /// lets us set a new password without knowing the current one.
    func rotate(to password: String) async -> Bool {
        guard Self.isShellSafe(password) else { return false }
        return await run("psql -U postgres -d postgres -c \"ALTER USER postgres PASSWORD '\(password)'\"")
    }

    func persist(_ password: String) throws {
        try KeychainManager.set(account: KeychainManager.postgresPasswordAccount, value: password)
    }

    func generatePassword() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func run(_ script: String) async -> Bool {
        do {
            let result = try await exec(containerId, ["sh", "-c", script])
            return result.exitCode == 0
        } catch {
            debugLog("[PostgresCredentials] exec failed: \(error)")
            return false
        }
    }

    /// Generated passwords are hex and the legacy password is a plain word, so
    /// anything else is refused rather than interpolated into a shell command.
    static func isShellSafe(_ password: String) -> Bool {
        !password.isEmpty && password.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
