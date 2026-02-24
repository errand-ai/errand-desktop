# Design: Add LiteLLM and Hindsight Services

## Context

ErrandDesktop manages five services (postgres, valkey, migrate, backend, worker). LiteLLM is already partially implemented — it has a container image, config generation, health check, and port forwarding — but is gated behind a `litellmEnabled: Bool` flag and managed via a separate `LiteLLMManager` class that runs the container outside the standard `ContainerEngine.startAll` loop. Hindsight is not implemented at all.

The current startup order is:
1. `[postgres]`
2. `[migrate, valkey]` — parallel
3. `[backend]`
4. `[worker]`

LiteLLM is dynamically inserted before backend by patching the order in `ContainerEngine.startAll` when enabled. LiteLLMManager also has its own image pull and container lifecycle that partially duplicates ContainerEngine logic.

## Goals / Non-Goals

**Goals:**
- Promote LiteLLM to a standard always-on service managed entirely by `ContainerEngine` (remove `LiteLLMManager` start/stop; keep its config-file generation and provider persistence)
- Add Hindsight as a new always-on service managed by `ContainerEngine`
- Run postgres and valkey in parallel in group 1
- Update the static `serviceStartupOrder` instead of dynamic patching
- Replace the OIDC settings tab with a Memory tab for Hindsight model configuration
- Update the LiteLLM image to `ghcr.io/berriai/litellm-database:main-v1.81.3-stable`

**Non-Goals:**
- Removing `LiteLLMManager` entirely — keep it for config-file generation (`generateConfigYAML`, `loadProviders`, `saveProviders`) and the `LiteLLMConfigView`
- Changing any OIDC functionality in the backend/worker (the OIDC env vars can remain in the backend build; this change only removes the settings UI)
- Changing how postgres, valkey, backend, or worker containers are started

## Decisions

### 1. LiteLLM managed by ContainerEngine, not LiteLLMManager

Currently `LiteLLMManager.start()` calls `ContainerEngine` to pull image and start the container, then `AppState.startAll` handles it separately after port forwarding. This is inconsistent.

**Decision**: Move LiteLLM fully into the standard `ContainerEngine` flow. `imageSpecs` returns the new image, `buildEnv` returns LiteLLM's env vars (database URL pointing to postgres), `buildMountObjects` returns the config virtiofs share, and `checkHealth` polls `/health`. The `LiteLLMManager.start()` and `stop()` methods become dead code and can be left as stubs or removed; `generateConfigYAML` and provider persistence are kept.

Rationale: Consistency. Every other service follows this pattern. Dynamic order patching is replaced by a static `serviceStartupOrder`.

### 2. Static startup order in ServiceInfo.swift

**New order:**
```swift
let serviceStartupOrder: [[String]] = [
    ["postgres", "valkey"],
    ["migrate", "litellm", "hindsight"],
    ["backend"],
    ["worker"],
]
```

`stopAll` in `ContainerEngine` also dynamically appends `["litellm"]` — this will be removed; the static order is used for both start and stop (reversed).

### 3. Hindsight container

- **Image**: `ghcr.io/vectorize-io/hindsight:latest-slim`
- **Port**: 8080 (default for Hindsight's HTTP API); exposed via `AppConfig.hindsightPort` defaulting to `8081` to avoid conflicts with other common services
- **Health check**: HTTP GET `/health` at the container IP on port 8080
- **Storage**: virtiofs share at `~/Library/Application Support/ErrandDesktop/data/hindsight` → `/data` in container (added to `StorageManager.ensureDataDirectories`)
- **Env vars passed to Hindsight**:
  - `DATABASE_URL` — postgres connection string
  - `HINDSIGHT_LLM_MODEL` — from `AppConfig.hindsightLLMModel`
  - `HINDSIGHT_EMBEDDING_MODEL` — from `AppConfig.hindsightEmbeddingModel`
  - `LITELLM_BASE_URL` — `http://<litellmIP>:4000` (constructed from litellm container IP)
- **Env vars injected into backend/worker**: `HINDSIGHT_BASE_URL` = `http://<hindsightIP>:8080`

### 4. LiteLLM database configuration

The new image `ghcr.io/berriai/litellm-database:main-v1.81.3-stable` uses postgres for its own data (model configs, usage tracking). It requires a `DATABASE_URL` env var pointing to the postgres container, plus `LITELLM_MASTER_KEY` for API authentication.

**Decision**: Add `DATABASE_URL` and `LITELLM_MASTER_KEY` to the litellm case in `buildEnv`. Generate a stable master key at first run (stored in Keychain alongside `credential-encryption-key`). Inject `LITELLM_BASE_URL` and `LITELLM_API_KEY` into backend and worker, replacing the existing direct `openaiBaseURL`/`openaiAPIKey` path (LiteLLM is now always present).

### 5. Memory settings tab — free-text model fields

The Memory tab in settings will provide two `TextField` inputs for `hindsightLLMModel` and `hindsightEmbeddingModel`. These are LiteLLM model name strings (e.g. `openai/gpt-4o`, `openai/text-embedding-3-small`). A dropdown would require querying the running LiteLLM instance at settings-open time, which is fragile. Free-text fields match the pattern used in `LLMTab` for `openaiBaseURL` and `openaiAPIKey`.

### 6. AppConfig changes

Remove: `litellmEnabled`, `oidcDiscoveryURL`, `oidcClientID`, `oidcClientSecret`
Add: `hindsightPort: Int = 8081`, `hindsightLLMModel: String = ""`, `hindsightEmbeddingModel: String = ""`

The OIDC fields are removed from AppConfig since the settings UI is removed. The backend still accepts OIDC env vars if needed but they won't be injected from AppConfig (the backend team manages its own OIDC configuration separately).

## Risks / Trade-offs

- **OIDC removal**: Removing OIDC from AppConfig means existing `config.json` files with OIDC fields will silently drop those values on next save. Since this is a local desktop app used by a single user, and OIDC for the local stack is unused in practice, this is acceptable. → Mitigation: none needed; values ignored on decode (Swift's Codable skips unknown keys when using `CodingKeys`).

- **LiteLLM image change**: The `-database` variant may have different startup behaviour or require schema migration if an older LiteLLM SQLite file exists in the data directory. → Mitigation: use a fresh postgres DB for LiteLLM data; the virtiofs config share is separate from the database.

- **Hindsight image availability**: `ghcr.io/vectorize-io/hindsight:latest-slim` is a third-party image; GHCR anonymous token exchange applies. → Mitigation: same pattern as existing vminit pull (anonymous bearer token exchange).

## Migration Plan

1. On app update, `config.json` is re-decoded: unknown fields (`litellmEnabled`, OIDC fields) are ignored; new fields default to their Swift defaults
2. `StorageManager.ensureDataDirectories` creates the `hindsight` subdir on first run
3. LiteLLM moves from its own container lifecycle to the standard flow; existing `data/litellm/` config files are preserved (virtiofs share path unchanged)
4. No data migration required

## Open Questions

- What `LITELLM_MASTER_KEY` value should be used — user-visible in settings, or auto-generated and stored in Keychain only? (Proposing: auto-generated, stored in Keychain, not exposed in UI)
- Does Hindsight's `/data` mount need to be ext4 (like postgres/valkey) or is virtiofs sufficient? (Proposing: virtiofs is fine; Hindsight doesn't need raw filesystem control)
- What is Hindsight's actual health check endpoint? (Proposing: `/health` — to be confirmed from image docs)
