# Add LiteLLM and Hindsight Services

## Why

ErrandDesktop currently deploys LiteLLM as an optional, user-toggled service and doesn't include Hindsight at all. Both services should be standard parts of the Errand stack — always deployed locally alongside postgres, valkey, backend, and worker. The startup order can also be optimised by starting postgres and valkey in parallel since they have no interdependency.

## What Changes

- LiteLLM changes from optional (gated by `litellmEnabled` config flag) to always-deployed; image updated to `ghcr.io/berriai/litellm-database:main-v1.81.3-stable`
- Hindsight added as a new always-deployed service (`ghcr.io/vectorize-io/hindsight:latest-slim`) that provides persistent memory; requires postgres
- Startup order updated: postgres and valkey now start in parallel (group 1), then migrate/litellm/hindsight start in parallel (group 2, all require postgres), then backend (group 3), then worker (group 4)
- `litellmEnabled` config flag and its associated UI toggle removed — LiteLLM is no longer optional
- `hindsightPort` added to `AppConfig` with a sensible default
- Settings page OIDC tab replaced with a Memory tab for configuring Hindsight's LLM Model and Embedding Model

## Capabilities

### New Capabilities

- `hindsight-service`: Hindsight persistent memory service — OCI image pull, container creation, startup, health checks, port forwarding, and env vars injected into backend/worker containers

### Modified Capabilities

- `container-commands`: Migrate concurrency group changes — migrate previously ran concurrently with Valkey; now postgres and Valkey start together in group 1, and migrate runs in group 2 alongside LiteLLM and Hindsight

## Impact

- `Sources/ErrandDesktop/Models/ServiceInfo.swift` — `serviceStartupOrder` updated to new 4-group order with parallel postgres+valkey and always-present litellm/hindsight
- `Sources/ErrandDesktop/Container/ContainerEngine.swift` — dynamic LiteLLM insertion logic removed; hindsight image, env vars, mounts, and health check cases added; startup order now static
- `Sources/ErrandDesktop/Models/AppConfig.swift` — `litellmEnabled` removed; `hindsightPort`, `hindsightLLMModel`, and `hindsightEmbeddingModel` added
- `Sources/ErrandDesktop/App/AppState.swift` — conditional LiteLLMManager start logic simplified; hindsight added to services list
- `Sources/ErrandDesktop/Views/SettingsView.swift` — OIDC tab replaced with Memory tab (LLM Model + Embedding Model selectors for Hindsight); LiteLLM enabled toggle removed from General tab
- `Sources/ErrandDesktop/Views/SetupAssistantView.swift` — LiteLLM enable step removed or repurposed
- `Sources/ErrandDesktop/Container/HealthChecker.swift` — hindsight health check case added
