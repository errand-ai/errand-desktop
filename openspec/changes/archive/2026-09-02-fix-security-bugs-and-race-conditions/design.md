## Context

A code review (GitHub issue #4) identified two critical security vulnerabilities, three high-severity bugs, and several medium-severity issues in the current codebase. The app is a macOS menu bar app that binds a local HTTP bridge server for worker containers and manages Postgres/Valkey via the Apple Containerization framework. The bridge server currently binds to `0.0.0.0` and serves the LiteLLM master key unauthenticated, making it accessible to any device on the local network. Postgres credentials are hardcoded as `postgres:postgres`. Two network continuation handlers use an unsynchronized `resumed` flag, which can crash the app via double-resume.

## Goals / Non-Goals

**Goals:**
- Bind `BridgeServer` to loopback only so it is unreachable from the local network
- Require bearer token auth on `/litellm-login` so the LiteLLM master key is not exposed unauthenticated
- Generate a random Postgres password at first run and store it in Keychain
- Fix double-resume race conditions in `DockerHTTPClient` and `HealthChecker`
- Set `0o700` on the secrets directory
- Cap log buffer at 10,000 entries
- Make `PortForwarder` thread-safe
- Add request body size limit and container ID validation to the bridge HTTP layer

**Non-Goals:**
- Moving `llmProviderAPIKey` or LiteLLM provider keys out of JSON (S5/S6 — deferred)
- Moving debug log file out of `/tmp` (S7 — low priority)
- Adding new test coverage (P4 — separate change)

## Decisions

### D1: Loopback binding for BridgeServer
Set `params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)` before creating the `NWListener`. The worker container reaches the bridge via the host gateway IP (typically `192.168.64.1` on vmnet), not via loopback — so the bridge must also listen on the host-side vmnet interface.

**Decision:** Bind to `NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)` for the loopback face AND the vmnet gateway interface. The gateway IP is already injected as `CONTAINER_BRIDGE_HOST` env var; use the same approach to find the active vmnet interface and bind to it. If the vmnet interface IP is not yet known at `start()` time, fall back to binding `0.0.0.0` only for the vmnet-facing interface, but log a warning.

**Alternative considered:** Single bind to loopback and use a socket proxy into the container network — rejected as more complexity and an additional port.

**Revised decision (simpler):** Bind to `0.0.0.0` but validate the source address on every incoming connection: reject connections whose remote address is not loopback (`127.0.0.1`) or the host's own vmnet gateway address. This avoids NWListener multi-bind complexity while still blocking arbitrary LAN hosts.

### D2: Auth on /litellm-login
The endpoint is opened in a system browser on the user's own Mac, so the caller is always the local user. Require the same bearer token already used for all other bridge routes. The token is injected into Worker as `CONTAINER_BRIDGE_TOKEN`; for the browser flow the host app opens the URL with the token in the Authorization header via a JavaScript redirect rather than raw browser fetch — but the browser cannot set Authorization headers.

**Decision:** Switch to a short-lived one-time token query parameter (`?token=<otp>`) generated on each call to `GET /litellm-login-url` (authenticated). The browser is directed to `/litellm-login?token=<otp>` which is valid for 60 seconds and consumed on first use.

**Alternative considered:** Remove the endpoint and have the user copy-paste the key — poor UX.

### D3: Postgres credential generation
Generate a 32-character alphanumeric password at first run using `UUID().uuidString.replacingOccurrences(of: "-", with: "")`. Store under Keychain service `sh.errand.ErrandDesktop` account `postgres-password`. On every subsequent start, read from Keychain. The `ContainerEngine` calls `KeychainManager.getOrCreatePostgresPassword()` before injecting `POSTGRES_PASSWORD` and `DATABASE_URL` env vars.

### D4: Mutex-protected resumed flag
Swift 6 stdlib ships `Mutex` (available via `import Synchronization`). Replace `nonisolated(unsafe) var resumed = false` with `let mutex = Mutex(false)` and use `mutex.withLock { ... }` to gate the guard and the assignment. The `withCheckedThrowingContinuation` block is `nonisolated`, so `Mutex` (which is `Sendable`) is the cleanest fix without changing the overall pattern.

**Alternative considered:** `os_unfair_lock` — works but requires unsafe pointer handling. `Mutex` is preferred for Swift 6.

### D5: Secrets directory permissions
After `createDirectory`, call `try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)`. Use `try` (not `try?`) so a permissions failure surfaces rather than silently failing.

### D6: Log ring buffer
Add a constant `private let maxLogEntries = 10_000`. In `appendLog`, after appending check `if logs.count > maxLogEntries { logs.removeFirst(logs.count - maxLogEntries) }`. This is O(n) but the buffer is bounded so it amortizes acceptably. An alternative ring buffer index approach is not worth the complexity at this scale.

### D7: PortForwarder → actor
Convert `final class PortForwarder: @unchecked Sendable` to `actor PortForwarder`. Remove the concurrent `DispatchQueue` from the struct. Callers that currently call synchronously must become `async`. Check all call sites in `AppState` / `ContainerEngine` and add `await`.

### D8: HTTP body size limit
Add a constant `let maxBodyBytes = 10 * 1024 * 1024` (10 MB) in `HTTPTypes.swift`. In the `parse` function, after reading `contentLength`, return `nil` (malformed) if `contentLength > maxBodyBytes`.

### D9: Container ID validation
In `parseContainerRoute`, validate `id` against the pattern `^[a-zA-Z0-9_-]{1,128}$`. Return `nil` if the ID contains path separators or other unexpected characters.

## Risks / Trade-offs

- **D1 source-address validation vs. bind restriction**: Validation approach (D1 revised) means the socket still binds to `0.0.0.0` for the vmnet interface. A misconfigured firewall or VPN with a spoofed source IP could theoretically bypass this, but is much better than the current unauthenticated situation.
- **D2 OTP token**: A very short window (60s) reduces replay risk. Token must be stored in memory only (not persisted), one-time use, cryptographically random.
- **D3 credential rotation**: Existing Postgres data initialized with `postgres:postgres` will fail to start after the fix unless the user wipes the data disk. → Detect by checking if the stored password differs from the initialized value; on mismatch log a clear error and prompt the user to reset Postgres data.
- **D7 actor conversion**: All callers of `PortForwarder.forward()` and `stopAll()` must add `await`. This is a minor refactor but must be done atomically.

## Migration Plan

1. Land all changes in a single PR (tightly coupled).
2. On first launch after upgrade, `KeychainManager.getOrCreatePostgresPassword()` generates a new password. If the Postgres container starts successfully, the user is unaffected. If it fails (because the disk was initialized with the old password), the UI shows a "Reset Postgres data" prompt.
3. No rollback path for Postgres credential change — users who downgrade will need to wipe data.

## Open Questions

- Should we also restrict which remote container IDs can call the bridge (i.e., only containers started by `ContainerEngine`)? Current scope says validate format only; full allowlist deferred.
