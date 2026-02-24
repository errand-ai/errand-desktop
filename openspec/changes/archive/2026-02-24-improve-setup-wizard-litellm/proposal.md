## Why

The setup wizard currently references "Content Manager" (an old project name) and treats LiteLLM as an advanced/optional feature that users must discover later. Since LiteLLM is the recommended way to manage LLM providers, it should be the default path during first-run setup. Users who already have an OpenAI-compatible endpoint should be able to opt out, but the happy path should guide them through starting LiteLLM and configuring providers via its UI.

## What Changes

- **Welcome screen text fix**: Change "This app runs the Content Manager stack locally" to "This app runs the Errand AI stack locally"
- **LiteLLM default opt-in**: LiteLLM is enabled by default during setup; users can toggle it off (opt-out model)
- **LLM Configuration step reworked** (step 2):
  - Toggle at the top: "Use LiteLLM" (on by default)
  - When LiteLLM is enabled: pull and start Postgres + LiteLLM containers inline, then show a button to open the LiteLLM UI in a browser
  - When LiteLLM is disabled: show Base URL and API Key text fields for direct OpenAI-compatible endpoint configuration
  - Base URL and API Key fields are greyed out / disabled when LiteLLM is enabled
- **Agent Memory step added** (step 3, new):
  - "Use Hindsight for Agent Memory" toggle, defaulting to on (opt-out model)
  - When enabled:
    - The worker container receives `HINDSIGHT_URL=http://hindsight:8888/` and `HINDSIGHT_BANK_ID=errand-tasks` at startup
    - The hindsight container receives: `HINDSIGHT_API_DATABASE_URL` (postgres connection), `HINDSIGHT_API_EMBEDDING_LITELLM_MODEL` (selected embedding model), `HINDSIGHT_API_EMBEDDING_PROVIDER=litellm`, `HINDSIGHT_API_LITELLM_API_BASE` (LLM base URL), `HINDSIGHT_API_LLM_BASE_URL` (LLM base URL), `HINDSIGHT_API_LLM_MODEL` (selected LLM model), `HINDSIGHT_API_LLM_PROVIDER=litellm`, `HINDSIGHT_API_PORT=8888`, `HINDSIGHT_API_LLM_API_KEY` (LLM API key, or `PROXY_MASTER_KEY` when using LiteLLM)
  - When disabled, hindsight container is excluded from startup and the worker does not receive these env vars
  - When enabled, fetch available models from the LLM base URL (`GET /v1/models`) and populate two dropdowns:
    - **LLM Model**: filtered by `mode=chat`; auto-select a `claude-sonnet-*` match if present
    - **Embedding Model**: filtered by `mode=embedding`
  - When disabled, both dropdowns are greyed out / disabled
- **Settings LLM tab reworked** to match the setup wizard:
  - "Use LiteLLM" toggle (on/off), reflecting `useLiteLLM` config
  - When LiteLLM is enabled: Base URL and API Key fields greyed out / disabled
  - When LiteLLM is disabled: Base URL and API Key fields editable
  - Placeholder text inside fields (not external labels)
- **Settings Memory tab reworked** to match the setup wizard:
  - "Use Hindsight for Agent Memory" toggle, reflecting `useHindsight` config
  - When enabled: fetch models from LLM base URL and populate LLM Model and Embedding Model dropdowns (filtered by `mode=chat` / `mode=embedding`), auto-select `claude-sonnet-*` for LLM Model if available
  - When disabled: both dropdowns greyed out / disabled
- **Placeholder text improvement**: Move example text ("sk-...", "https://api.openai.com/v1") from external labels into the text fields as placeholder text (greyed out, disappears on typing) — applies to both the setup wizard and the Settings LLM tab

## Capabilities

### New Capabilities

- `setup-wizard-litellm-flow`: Covers the reworked LLM Configuration step in the setup wizard — LiteLLM toggle, inline container startup (Postgres + LiteLLM), "Open LiteLLM UI" button, and conditional display of Base URL / API Key fields
- `setup-wizard-hindsight-flow`: Covers the new Agent Memory step in the setup wizard — Hindsight opt-out toggle, conditional worker env vars (`HINDSIGHT_URL`, `HINDSIGHT_BANK_ID`), and conditional hindsight container inclusion in startup

### Modified Capabilities

_(none — no existing spec-level requirements are changing)_

## Impact

- **Views**: `SetupAssistantView.swift` (welcome text, reworked LLM step), `SettingsView.swift` (placeholder text fix in LLM tab)
- **Models**: `AppConfig.swift` (new `useLiteLLM: Bool` field default `true`, new `useHindsight: Bool` field default `true`)
- **App State**: `AppState.swift` (new methods to pull/start Postgres + LiteLLM during setup, expose LiteLLM running state for the wizard, new method to fetch available models from LLM base URL for Hindsight model selection)
- **Container Engine**: `ContainerEngine.swift` — update LiteLLM env vars to include `HOST`, `PORT`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_URL`, `PROXY_MASTER_KEY`, `LITELLM_MODE`, `LITELLM_PROXY_CONNECTION_TIMEOUT`; update config mount from `/app/config` to `/etc/litellm/config.yaml`; rename `LITELLM_MASTER_KEY` → `PROXY_MASTER_KEY`; rework hindsight env vars to use `HINDSIGHT_API_*` prefix format with selected models and conditional LLM API key; conditionally add `HINDSIGHT_URL` and `HINDSIGHT_BANK_ID` to worker env when hindsight is enabled; conditionally exclude hindsight from `serviceStartupOrder` when disabled
- **Keychain**: `KeychainManager.swift` — add a new key generation method producing `sk-<18 random alphanumeric chars>` format (existing `litellm-master-key` account stays, but newly generated keys use the `sk-` prefix format)
- **Config**: `configs/litellm.yaml` — populate with a minimal default LiteLLM config
- **Persistence**: `config.json` gains `useLiteLLM` and `useHindsight` fields; existing configs without them default to `true`
