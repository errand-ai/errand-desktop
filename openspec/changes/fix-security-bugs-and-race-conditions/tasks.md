## 1. BridgeServer Network Hardening

- [ ] 1.1 Add source-address validation in `BridgeServer.accept()` — reject connections not from 127.0.0.1 or the vmnet gateway IP
- [ ] 1.2 Add `GET /litellm-login-url` endpoint (authenticated) that generates and stores a 60-second one-time token
- [ ] 1.3 Remove the unauthenticated bypass for `GET /litellm-login` and require the OTP query parameter
- [ ] 1.4 Validate container ID format in `parseContainerRoute()` using `^[a-zA-Z0-9_-]{1,128}$`
- [ ] 1.5 Add `maxBodyBytes = 10 * 1024 * 1024` constant and enforce it in `HTTPTypes.swift` `parse()`; return HTTP 413 on violation

## 2. Postgres Credential Hardening

- [ ] 2.1 Add `getOrCreatePostgresPassword() -> String` to `KeychainManager` — generates 32-char random password on first call, stores and returns stored value thereafter
- [ ] 2.2 Replace hardcoded `postgres:postgres` in `ContainerEngine` (all 5 occurrences) with `KeychainManager.getOrCreatePostgresPassword()`
- [ ] 2.3 Update `DATABASE_URL` construction for Backend, Worker, LiteLLM, and Hindsight to use the stored password

## 3. Race Condition Fixes

- [ ] 3.1 Replace `nonisolated(unsafe) var resumed = false` in `DockerHTTPClient.connect()` with `let mutex = Mutex(false)` and use `mutex.withLock` as guard/assignment
- [ ] 3.2 Replace `nonisolated(unsafe) var resumed = false` in `HealthChecker` TCP check with `Mutex`-protected flag (same pattern including the timeout closure)

## 4. Secrets Directory Permissions

- [ ] 4.1 Change secrets directory creation in `KeychainManager` to use `try` instead of `try?` and immediately follow with `try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)`

## 5. Log Buffer Cap

- [ ] 5.1 Add `private let maxLogEntries = 10_000` constant to `AppState`
- [ ] 5.2 In `appendLog`, after `logs.append(...)`, trim `logs` to `maxLogEntries` by removing leading entries if count exceeds the limit

## 6. PortForwarder Thread Safety

- [ ] 6.1 Convert `final class PortForwarder: @unchecked Sendable` to `actor PortForwarder`
- [ ] 6.2 Remove the `private let queue` DispatchQueue from `PortForwarder`
- [ ] 6.3 Update all call sites of `PortForwarder.forward()` and `stopAll()` in `AppState`/`ContainerEngine` to use `await`

## 7. Verification

- [ ] 7.1 Run `swift build` and confirm zero errors and zero warnings related to these changes
- [ ] 7.2 Manually test: confirm bridge server rejects a curl request from a non-loopback address
- [ ] 7.3 Manually test: confirm `/litellm-login` without token returns 401
- [ ] 7.4 Manually test: confirm app starts cleanly and Postgres initializes with the generated password on a fresh data directory
