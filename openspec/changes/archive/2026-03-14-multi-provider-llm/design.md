## Context

The errand-server has migrated from a single `OPENAI_BASE_URL`/`OPENAI_API_KEY` to indexed `LLM_PROVIDER_N_*` environment variables. The desktop app currently injects the old format into backend and worker containers. It also uses a binary `useLiteLLM` toggle that either deploys LiteLLM locally or falls back to a single OpenAI-style base URL and API key.

The desktop app manages a single LLM provider (not multiple like the server's settings UI) because it only needs one provider for passing to containers. Users who want multiple providers can configure them in the errand settings UI after the stack is running.

## Goals / Non-Goals

**Goals:**
- Give users a clear choice: deploy LiteLLM locally or connect to an external provider
- Pass provider configuration using the new indexed env var format (`LLM_PROVIDER_0_*`)
- Detect external provider type to enable model listing where possible
- Adapt Hindsight model selection to provider capabilities (dropdown vs free text)
- Provide contextual documentation links in the setup wizard

**Non-Goals:**
- Supporting multiple providers in the desktop app (that's the errand settings UI's job)
- Migrating existing user configs (no existing users)
- Changing the LiteLLM pre-configuration flow (LiteLLMManager, providers.json, config.yaml)
- Changing Hindsight's own environment variable format

## Decisions

### 1. Single provider in AppConfig rather than a provider array

The desktop app configures one provider that serves as the default `LLM_PROVIDER_0`. This keeps the config and UI simple. Users needing multiple providers configure them via the errand settings UI after the stack is running.

**Alternative**: Mirror the server's multi-provider model. Rejected — adds complexity without clear value for the desktop use case where the app primarily needs one provider to bootstrap the stack.

### 2. Always populate provider fields, even for local LiteLLM

When `deployLiteLLM` is true, the provider fields are derived at startup:
- `llmProviderName` = "LiteLLM"
- `llmProviderBaseURL` = `http://{litellmContainerIP}:4000/v1` (inter-container URL)
- `llmProviderAPIKey` = scoped `errandServiceKey` (from litellm-service-keys provisioning)
- `llmProviderType` = "litellm"

This makes `buildEnv` uniform — it always reads from the same fields regardless of deployment mode.

**Alternative**: Only persist fields for external providers and have `buildEnv` branch on `deployLiteLLM`. Rejected — more conditional logic, same outcome.

### 3. Provider detection via sequential HTTP probing

For external providers, detection runs in Swift using URLSession:

1. Strip `/v1` suffix from base URL if present
2. Try `GET {stripped_url}/model/info` — if 200 with `{"data": [...]}`, type is `litellm`
3. Try `GET {base_url}/models` — if 200 with `{"data": [...]}`, type is `openai_compatible`
4. Otherwise, type is `unknown`

Both requests include `Authorization: Bearer {api_key}` and a 10-second timeout. This matches the errand-server's `probe_provider_type()` logic.

Detection runs once after the user enters base URL and API key, and results are persisted in `llmProviderType`. Re-detection only triggers if the user changes the URL or API key.

### 4. Model fetching adapts to provider type

| Provider Type | Fetch Endpoint | Model Selection UI |
|---|---|---|
| `litellm` | `GET {base_url}/../model/info` | Dropdown (filtered by mode) |
| `openai_compatible` | `GET {base_url}/models` | Dropdown |
| `unknown` | None | Free text entry |

For Hindsight model selection:
- `litellm`: Separate chat and embedding models by `mode` field from `/model/info`
- `openai_compatible`: List all models from `/models` (no mode filtering — standard OpenAI endpoint doesn't include mode metadata)
- `unknown`: Two free text fields for LLM model and embedding model names

### 5. Env var injection mapping

**Backend and Worker containers:**
```
LLM_PROVIDER_0_NAME     = llmProviderName
LLM_PROVIDER_0_BASE_URL = llmProviderBaseURL (inter-container URL)
LLM_PROVIDER_0_API_KEY  = errandServiceKey (local LiteLLM) or llmProviderAPIKey (external)
```

**Hindsight container** (unchanged format):
```
HINDSIGHT_API_LLM_BASE_URL                    = llmProviderBaseURL (inter-container URL)
HINDSIGHT_API_LLM_API_KEY                     = hindsightServiceKey (local LiteLLM) or llmProviderAPIKey (external)
HINDSIGHT_API_LLM_MODEL                       = config.hindsightLLMModel
HINDSIGHT_API_EMBEDDINGS_LITELLM_MODEL        = config.hindsightEmbeddingModel
HINDSIGHT_API_LLM_PROVIDER                    = "openai" (or "litellm" if local)
HINDSIGHT_API_EMBEDDINGS_PROVIDER             = "litellm" (or "openai" if external)
```

### 6. Setup wizard step layout

```
Step 0: Welcome
Step 1: Runtime (Docker / Apple Containerization)
Step 2: LLM Provider Choice
         ├─ Radio: "Deploy LiteLLM locally" (recommended)
         │   Brief description + link to errand.sh/docs/ai-models/
         └─ Radio: "Connect to an existing provider"
             Name, Base URL, API Key fields
             Detection result shown after probing
Step 3: Start Services (only if deploying LiteLLM locally)
         Start Postgres + LiteLLM, show progress, Open LiteLLM UI button
Step 4: Hindsight
         Brief description + link to errand.sh/docs/ai-memory/
         Toggle on/off
         Model selection (dropdown or free text based on provider type)
Step 5: Version
Step 6: Image Pull
Step 7: Done
```

Step 3 is skipped when connecting to an external provider (same skip logic as current "LiteLLM disabled" path).

## Risks / Trade-offs

**Provider detection may be slow or fail for firewalled endpoints** → 10-second timeout per probe, graceful fallback to "unknown" type. User can still proceed with free text model entry.

**OpenAI-compatible providers may not support mode filtering** → For `openai_compatible` type, show all models in both dropdowns without filtering. User selects appropriate models.

**Scoped service keys only exist for local LiteLLM** → When using an external provider, `LLM_PROVIDER_0_API_KEY` is the user-provided key directly. This is expected — key scoping is a LiteLLM feature.

**External LiteLLM detection may false-positive** → The `/model/info` endpoint is fairly LiteLLM-specific. Risk is low. If misdetected, the user still gets a working dropdown — slightly different filtering behavior is acceptable.
