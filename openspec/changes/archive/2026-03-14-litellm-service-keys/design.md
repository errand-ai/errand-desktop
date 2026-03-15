## Context

All containers needing LLM access (Backend, Worker, Task Runners, Hindsight) receive the LiteLLM master key directly. This key has full admin access to LiteLLM's management API. LiteLLM supports virtual API keys via `POST /key/generate`, which creates scoped keys stored in its Postgres database. The app already stores the master key in the macOS Keychain and injects it via `ContainerEngine.buildEnv()`.

Two startup paths exist:
1. **Setup wizard** (`AppState.startSetupServices()`): starts only Postgres + LiteLLM, then the user proceeds to the Agent Memory step which queries `/model/info`
2. **Normal startup** (`ContainerEngine.startAll()`): starts all services in dependency order via `serviceDependencies` graph

Both paths need key provisioning after LiteLLM becomes healthy and before dependent services consume the keys.

## Goals / Non-Goals

**Goals:**
- Generate two scoped virtual API keys (`errand-services`, `hindsight-services`) via LiteLLM's REST API
- Persist keys in macOS Keychain for reuse across restarts
- Detect stale keys and regenerate automatically
- Inject the correct scoped key into each container's environment
- Work identically across Docker and Apple Containerization runtimes

**Non-Goals:**
- Per-model or per-budget key restrictions (all models accessible, no spend limits)
- Key rotation on a schedule (keys are long-lived, only regenerated when stale)
- Changing how the master key is used for LiteLLM's own config or host-side admin queries
- Changing how keys work when `useLiteLLM` is false (direct `config.openaiAPIKey` pass-through)

## Decisions

### 1. Key provisioning lives in ContainerEngine

**Decision**: Add a `provisionServiceKeys()` method to `ContainerEngine` that makes HTTP calls to LiteLLM's `/key/generate` endpoint.

**Rationale**: ContainerEngine already holds `litellmMasterKey` and the service key properties that `buildEnv()` reads. Keeping generation and consumption in the same actor avoids cross-actor synchronization. Both `startAll()` and `startSetupServices()` can call it — `startAll()` calls it internally after LiteLLM health check passes, `startSetupServices()` in AppState calls it explicitly after LiteLLM is healthy.

**Alternative considered**: Put provisioning in AppState (which already uses `URLSession` in `fetchAvailableModels()`). Rejected because the keys are consumed by ContainerEngine's `buildEnv()` — having AppState generate keys and pass them down via setters adds unnecessary indirection.

### 2. Keychain-first with validation

**Decision**: On startup, check the Keychain for existing keys first. If found, validate against LiteLLM with `GET /key/info?key=<key>`. If valid, use them. If missing or stale, generate new keys and store in Keychain.

**Rationale**: LiteLLM only returns the full key value at creation time (it's hashed in the DB after that). So we must persist keys ourselves. Validation catches the case where LiteLLM's DB was reset (e.g. user deleted Postgres data) but Keychain still has old keys.

**Alternative considered**: Delete and recreate keys on every startup. Rejected — wasteful and creates a brief window where no keys exist.

### 3. URL resolution differs by runtime

**Decision**: When making HTTP calls to LiteLLM for key provisioning, use `localhost:{litellmPort}` on Docker and `{containerIP}:4000` on Apple Containerization.

**Rationale**: Docker for Mac doesn't expose container IPs to the host — containers are only reachable via published ports on localhost. Apple Containerization uses vmnet, where container IPs are directly reachable from the host. Port forwarding hasn't been set up yet at the point where provisioning runs.

### 4. Two keys with `key_type: "default"`

**Decision**: Create keys with `key_type: "default"` rather than `"llm_api"`.

**Rationale**: The `llm_api` type restricts keys to LLM API routes only, but it's undocumented which exact routes are allowed. Using `"default"` ensures the keys can access `/models` and `/model/info` if needed, without admin capabilities. We can tighten to `"llm_api"` later once route restrictions are verified.

### 5. Master key stays for host-side operations

**Decision**: The master key continues to be used for: LiteLLM's own `PROXY_MASTER_KEY` / `LITELLM_MASTER_KEY` env vars, `fetchAvailableModels()` in AppState, and the LiteLLM UI login page in BridgeServer.

**Rationale**: These are admin operations performed by the host app itself, not by containers. The host app is the key management authority — it would be circular for it to use a key it generated.

## Risks / Trade-offs

**[LiteLLM DB reset invalidates keys]** → Validation on startup via `GET /key/info` detects stale keys. Regeneration is automatic. Brief log message on regeneration for visibility.

**[LiteLLM not yet fully ready when /key/generate is called]** → Health check already confirms LiteLLM is responsive before provisioning runs. Add a short retry (2-3 attempts) around the key generation calls.

**[Keychain and LiteLLM DB out of sync]** → If Keychain has keys that LiteLLM doesn't know about: validation detects this and regenerates. If LiteLLM has keys that Keychain doesn't: orphaned keys in LiteLLM DB are harmless; new keys are generated.

**[Network error during provisioning]** → If key generation fails, fall back to the master key and log a warning. Services can still start — they just use the master key as today. This makes the change non-breaking even on failure.
