## Why

A comprehensive code review (GitHub issue #4) identified two critical security vulnerabilities, three high-severity bugs, and several medium-severity issues in errand-desktop that expose the bridge server to the local network, leak the LiteLLM master key unauthenticated, and introduce race conditions that can crash the app. These must be fixed before any wider distribution.

## What Changes

- **BridgeServer** validates the source address of every inbound connection, accepting only loopback and peers on the vmnet gateway subnet (the socket still binds all interfaces so worker containers can reach it — see design decision D1); `/litellm-login` now requires a short-lived one-time token, minted by the new authenticated `/litellm-login-url` endpoint
- **Postgres credentials** generated randomly at first run and stored in Keychain instead of hardcoded `postgres:postgres`
- **Race conditions** in `DockerHTTPClient` and `HealthChecker` eliminated by protecting the `resumed` flag with a `Mutex`
- **Secrets directory** created with `0o700` permissions instead of `0o755`
- **Log buffer** capped at 10,000 entries with a ring-buffer approach to prevent unbounded memory growth
- **PortForwarder** made thread-safe by converting to an `actor`
- **HTTP request body** size capped in `HTTPTypes` to prevent allocation-based DoS
- **Container ID** validated in bridge routes to prevent path traversal

## Capabilities

### New Capabilities
- `bridge-server-hardening`: Source-address validation on every connection, one-time-token auth for `/litellm-login`, container ID validation, request body size limit

### Modified Capabilities
- `litellm-service-keys`: Postgres credentials now generated randomly at first run and stored in Keychain; delta spec needed for credential management requirement change

## Impact

- `Sources/ErrandDesktop/Bridge/BridgeServer.swift` — source-address validation, one-time-token auth on `/litellm-login`, container ID validation, body size limit
- `Sources/ErrandDesktop/ContainerEngine.swift` — random Postgres credential generation
- `Sources/ErrandDesktop/KeychainManager.swift` — store/retrieve Postgres credentials; secrets directory permissions
- `Sources/ErrandDesktop/DockerHTTPClient.swift` — `Mutex`-protected `resumed` flag
- `Sources/ErrandDesktop/HealthChecker.swift` — `Mutex`-protected `resumed` flag
- `Sources/ErrandDesktop/AppState.swift` — log ring buffer (cap 10,000)
- `Sources/ErrandDesktop/PortForwarder.swift` — convert to `actor`
- `Sources/ErrandDesktop/HTTPTypes.swift` — request body size limit
