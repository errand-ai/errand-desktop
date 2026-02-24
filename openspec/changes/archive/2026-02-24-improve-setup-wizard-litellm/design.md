## Context

The setup wizard (`SetupAssistantView`) is a 4-step flow: Welcome → LLM Config → Image Pull → Done. LiteLLM and Hindsight are included in `serviceStartupOrder` but have no setup wizard integration — they start silently as part of `startAll`. The current LLM step only collects a Base URL and API Key for a direct OpenAI-compatible endpoint.

The `ContainerEngine.startAll` orchestrates all services in dependency order using `serviceStartupOrder`. There is no mechanism to start a subset of services independently, which the wizard's LLM step now requires (start Postgres + LiteLLM inline before the full startup).

`AppConfig` has no `useLiteLLM` or `useHindsight` flags — these services always start.

## Goals / Non-Goals

**Goals:**

- Make LiteLLM the default LLM path during first-run setup (opt-out, not opt-in)
- Add an Agent Memory (Hindsight) step with model selection driven by the running LLM endpoint
- Align Settings tabs (LLM, Memory) with the wizard's UX patterns
- Update container env vars for LiteLLM and Hindsight to match their actual requirements
- Generate LiteLLM master key in `sk-<18 alphanumeric>` format

**Non-Goals:**

- Reworking the full `startAll` orchestration — we add a targeted `startSetupServices` method, not a general partial-start mechanism
- Changing the Image Pull step (step 4) — it continues to pull all remaining service images
- Adding LiteLLM provider configuration to the setup wizard — users configure providers via the LiteLLM UI after setup
- Changing the Hindsight container image or health check endpoint

## Decisions

### 1. Setup wizard step structure: 5 steps instead of 4

The wizard becomes: Welcome (0) → LLM Config (1) → Agent Memory (2) → Image Pull (3) → Done (4).

`totalSteps` changes from 4 to 5. The step indices in the `switch` statement shift accordingly.

**Rationale**: Agent Memory is a distinct concern from LLM configuration. Separating them keeps each step focused and avoids an overly long form.

### 2. Inline container startup during the wizard (Postgres + LiteLLM)

Add a new `AppState.startSetupServices()` method that starts only Postgres and LiteLLM (in that order, respecting the existing dependency). This reuses `ContainerEngine` primitives (`pullImage`, `createAndStartContainer`, `waitForHealthy`) but not `startAll`.

The method:
1. Pulls the Postgres image, creates and starts the container, waits for healthy
2. Pulls the LiteLLM image, creates and starts the container (with Postgres IP for `DATABASE_URL`), waits for healthy
3. Updates `services` array with container IDs and IPs
4. Sets up port forwarding for LiteLLM so `localhost:4000` works for "Open LiteLLM UI"

This runs as a `.task` on the LLM Config step when `useLiteLLM` is true. Progress is shown inline (pulling → starting → running). The "Open LiteLLM UI" button enables only when LiteLLM reaches `.running`.

**Alternative considered**: Reusing `startAll` with a filter parameter. Rejected because `startAll` processes all groups in `serviceStartupOrder` and has assumptions about the full set of services. A targeted method is simpler and safer.

### 3. Model fetching from `/v1/models` endpoint

Add an `AppState.fetchAvailableModels()` method that calls `GET http://localhost:{litellmPort}/v1/models` (via the port-forwarded LiteLLM) and parses the OpenAI-compatible response.

The response shape is:
```json
{
  "data": [
    { "id": "claude-sonnet-4-20250514", "mode": "chat", ... },
    { "id": "text-embedding-3-small", "mode": "embedding", ... }
  ]
}
```

Models are filtered into two lists by `mode` field. The LLM Model dropdown auto-selects the first `claude-sonnet-*` match. Both dropdowns are `Picker` controls.

If LiteLLM is not enabled, models are fetched from `config.openaiBaseURL` instead (with `config.openaiAPIKey` as bearer token).

If fetching fails (LiteLLM not ready, network error), show an empty picker with a retry button.

**Rationale**: Using the port-forwarded localhost URL (not the container IP directly) ensures consistency — it's the same URL the user would use in a browser.

### 4. `AppConfig` additions

```swift
var useLiteLLM: Bool = true
var useHindsight: Bool = true
var hindsightLLMModel: String = ""        // already exists
var hindsightEmbeddingModel: String = ""  // already exists
```

`useLiteLLM` and `useHindsight` default to `true`. Existing `config.json` files without these fields will decode with defaults via `Codable`.

### 5. Conditional service startup in `startAll`

`ContainerEngine.startAll` needs to skip `litellm` when `config.useLiteLLM == false` and skip `hindsight` when `config.useHindsight == false`. Rather than changing `serviceStartupOrder` (which is a global constant), filter services within `startAll`:

```swift
let skipServices: Set<String> = {
    var skip = Set<String>()
    if !config.useLiteLLM { skip.insert("litellm") }
    if !config.useHindsight { skip.insert("hindsight") }
    return skip
}()
```

Then in the group loop: `guard !skipServices.contains(serviceId)`.

When LiteLLM is disabled, the backend/worker env vars fall back to `config.openaiBaseURL` and `config.openaiAPIKey` directly (existing logic in `buildEnv` already handles this via `serviceIPs["litellm"]` being nil).

### 6. LiteLLM master key format: `sk-<18 alphanumeric>`

Add `KeychainManager.generateLiteLLMKey() -> String` that produces `sk-` followed by 18 random characters from `[a-zA-Z0-9]`.

The existing `litellm-master-key` keychain account is kept. On first access (no existing key), the new format is used. Existing keys are not migrated — they continue to work since LiteLLM accepts any string as `PROXY_MASTER_KEY`.

### 7. LiteLLM container env vars (full set)

Replace the current minimal env with:

| Env var | Value |
|---------|-------|
| `HOST` | `0.0.0.0` |
| `PORT` | `4000` |
| `DATABASE_USERNAME` | `postgres` |
| `DATABASE_PASSWORD` | `postgres` |
| `DATABASE_HOST` | `{postgresIP}` |
| `DATABASE_NAME` | `litellm` |
| `DATABASE_URL` | `postgresql://postgres:postgres@{postgresIP}:5432/litellm` |
| `PROXY_MASTER_KEY` | `{litellmMasterKey}` |
| `LITELLM_MODE` | `PRODUCTION` |
| `LITELLM_PROXY_CONNECTION_TIMEOUT` | `600` |

Remove the old `LITELLM_MASTER_KEY` env var. Update the config mount from `/app/config` to `/etc/litellm/config.yaml` (single file mount, not directory).

### 8. Hindsight container env vars (full set)

Replace the current `DATABASE_URL` + `HINDSIGHT_BASE_URL` env with:

| Env var | Value |
|---------|-------|
| `HINDSIGHT_API_DATABASE_URL` | `postgresql://postgres:postgres@{postgresIP}:5432/hindsight` |
| `HINDSIGHT_API_EMBEDDING_LITELLM_MODEL` | `{config.hindsightEmbeddingModel}` |
| `HINDSIGHT_API_EMBEDDING_PROVIDER` | `litellm` |
| `HINDSIGHT_API_LITELLM_API_BASE` | `http://{litellmIP}:{litellmPort}/v1` (or `config.openaiBaseURL`) |
| `HINDSIGHT_API_LLM_BASE_URL` | same as above |
| `HINDSIGHT_API_LLM_MODEL` | `{config.hindsightLLMModel}` |
| `HINDSIGHT_API_LLM_PROVIDER` | `litellm` |
| `HINDSIGHT_API_PORT` | `8888` |
| `HINDSIGHT_API_LLM_API_KEY` | `{litellmMasterKey}` if using LiteLLM, else `{config.openaiAPIKey}` |

The health check port also needs to change from `8080` to `8888` in both `ContainerEngine` and `HealthChecker`.

### 9. Worker env vars for Hindsight

When `config.useHindsight` is true and hindsight is running, add to the worker env:

| Env var | Value |
|---------|-------|
| `HINDSIGHT_URL` | `http://{hindsightIP}:8888/` |
| `HINDSIGHT_BANK_ID` | `errand-tasks` |

Replace the existing `HINDSIGHT_BASE_URL` env var.

### 10. LiteLLM config mount

Update `buildMountObjects` for `litellm`: mount `configs/litellm.yaml` (from the app bundle or data directory) as a single file to `/etc/litellm/config.yaml`. The `configs/litellm.yaml` in the repo should contain a minimal valid config (empty model list is fine — users add models via the LiteLLM UI which writes to the database).

### 11. Settings tabs mirror wizard UX

**LLM Tab**: Add a `Toggle("Use LiteLLM", isOn: $appState.config.useLiteLLM)` at the top. When on, disable the Base URL and API Key fields. Use `prompt:` parameter on `TextField`/`SecureField` for placeholder text instead of `LabeledContent` labels.

**Memory Tab**: Replace the current text fields with a `Toggle("Use Hindsight", isOn: $appState.config.useHindsight)` and two `Picker` dropdowns for LLM Model and Embedding Model, populated by fetching `/v1/models`. Both pickers are disabled when Hindsight is off. Reuse the same `fetchAvailableModels()` method from AppState.

### 12. Hindsight ServiceInfo port update

The Hindsight service definition currently has `port: 8081, containerPort: 8080`. This should change to `port: 8081, containerPort: 8888` to match `HINDSIGHT_API_PORT=8888`.

## Risks / Trade-offs

- **[Wizard blocks on container startup]** → If Postgres or LiteLLM fail to start during setup, the user is stuck on the LLM Config step. **Mitigation**: Show clear error messages with a retry button. Allow the user to toggle LiteLLM off and proceed with manual Base URL/API Key entry.
- **[Model fetch timing]** → The `/v1/models` call on step 3 depends on LiteLLM being healthy from step 2. If the user navigates quickly, models may not be loaded yet. **Mitigation**: Show a loading spinner and fetch on `.task` when the step appears. Allow retry.
- **[Existing keychain keys]** → Users upgrading from the current version have a base64-format master key in the keychain. This is fine — LiteLLM accepts any string for `PROXY_MASTER_KEY`. New installs get the `sk-` format.
- **[Config migration]** → Existing `config.json` files lack `useLiteLLM` and `useHindsight`. **Mitigation**: `Codable` defaults handle this — both default to `true`, which is the desired behavior.
- **[Port 8888 vs 8080 for Hindsight]** → Changing the container port from 8080 to 8888 affects health checks. **Mitigation**: Update both `ContainerEngine` and `HealthChecker` in the same commit.
