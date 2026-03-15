## Why

All containers that talk to LiteLLM (Backend, Worker, Task Runners, Hindsight) currently receive the LiteLLM master key as their API key. The master key has full admin access — it can create/delete models, manage keys, and read spend data. A compromised container could do anything. Instead, the app should generate scoped virtual API keys via LiteLLM's `/key/generate` endpoint and give each service only the access it needs. This also enables LiteLLM's per-key usage tracking to distinguish Errand vs Hindsight API spend.

## What Changes

- After LiteLLM becomes healthy (in both `startAll()` and `startSetupServices()`), the app generates two virtual API keys via `POST /key/generate` using the master key for auth
- Keys are stored in the macOS Keychain (`litellm-errand-key`, `litellm-hindsight-key`) and reused across restarts
- On startup, existing keys are validated against LiteLLM; stale keys (e.g. after a LiteLLM DB reset) are regenerated
- `ContainerEngine.buildEnv()` passes the errand service key to Backend/Worker containers and the hindsight service key to the Hindsight container
- The master key remains in use for LiteLLM's own config (`PROXY_MASTER_KEY`), the host-side model queries (`fetchAvailableModels`), and the LiteLLM UI login page

## Capabilities

### New Capabilities
- `litellm-service-keys`: Provisioning, persisting, validating, and injecting scoped LiteLLM virtual API keys for errand and hindsight services

### Modified Capabilities
- `setup-wizard-litellm-flow`: Key provisioning must happen after LiteLLM starts in the setup wizard, before the Agent Memory step can query models via a service key
- `hindsight-service`: Hindsight containers receive a dedicated hindsight service key instead of the master key

## Impact

- **KeychainManager**: Two new Keychain accounts (`litellm-errand-key`, `litellm-hindsight-key`)
- **ContainerEngine**: New `provisionServiceKeys()` method with HTTP calls to LiteLLM API; new `errandServiceKey` and `hindsightServiceKey` properties; `buildEnv()` updated to use service keys
- **AppState**: `startSetupServices()` calls key provisioning after LiteLLM healthy; `startAll()` path triggers provisioning via ContainerEngine
- **URL resolution**: Docker uses `localhost:{port}`, Apple Containerization uses `{containerIP}:4000` for the provisioning HTTP calls
