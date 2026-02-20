import Foundation

/// Result of a migration run.
struct MigrationResult: Sendable {
    let success: Bool
    let output: String
    let errorOutput: String
}

/// Runs Alembic database migrations on startup.
/// Executes inside the backend container (or a short-lived migration container)
/// after PostgreSQL is healthy but before the backend starts serving requests.
actor MigrationRunner {
    private let containerEngine: ContainerEngine

    init(containerEngine: ContainerEngine) {
        self.containerEngine = containerEngine
    }

    /// Runs `alembic upgrade head` inside the backend container.
    /// Returns a `MigrationResult` with stdout/stderr output.
    ///
    /// - Parameter backendContainerId: The container ID of the backend service.
    /// - Returns: The migration result including success status and output.
    func runMigrations(backendContainerId: String) async throws -> MigrationResult {
        let command = ["alembic", "upgrade", "head"]

        let (exitCode, stdout, stderr) = try await containerEngine.execInContainer(
            containerId: backendContainerId,
            command: command
        )

        return MigrationResult(
            success: exitCode == 0,
            output: stdout,
            errorOutput: stderr
        )
    }

    /// Runs migrations and handles the result, updating app state accordingly.
    /// Call this after PostgreSQL is healthy but before starting the backend server.
    ///
    /// - Parameters:
    ///   - backendContainerId: The container ID to exec into.
    ///   - onLog: Callback to send log output to the UI.
    /// - Returns: true if migrations succeeded, false otherwise.
    func runAndReport(
        backendContainerId: String,
        onLog: @Sendable (String, String) -> Void
    ) async throws -> Bool {
        onLog("migration", "Running Alembic migrations...")

        let result = try await runMigrations(backendContainerId: backendContainerId)

        if !result.output.isEmpty {
            onLog("migration", result.output)
        }

        if result.success {
            onLog("migration", "Migrations completed successfully.")
        } else {
            onLog("migration", "Migration FAILED:")
            if !result.errorOutput.isEmpty {
                onLog("migration", result.errorOutput)
            }
        }

        return result.success
    }
}
