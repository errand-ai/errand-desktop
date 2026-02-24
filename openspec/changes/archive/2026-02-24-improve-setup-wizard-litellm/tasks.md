## 1. Config & Keychain

- [x] 1.1 Add `useLiteLLM: Bool = true` and `useHindsight: Bool = true` fields to `AppConfig`
- [x] 1.2 Add `KeychainManager.generateLiteLLMKey() -> String` that produces `sk-` followed by 18 random alphanumeric characters (upper/lowercase + digits)
- [x] 1.3 Update `AppState.initialize()` to use the new key generation format for the `litellm-master-key` keychain account
- [x] 1.4 Create a minimal `configs/litellm.yaml` default config file

## 2. Container Engine — LiteLLM Env & Mount

- [x] 2.1 Update `buildEnv` for `litellm` case: set `HOST`, `PORT`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_URL`, `PROXY_MASTER_KEY`, `LITELLM_MODE`, `LITELLM_PROXY_CONNECTION_TIMEOUT` (remove old `LITELLM_MASTER_KEY`)
- [x] 2.2 Update `buildMountObjects` for `litellm` case: mount config as single file at `/etc/litellm/config.yaml` instead of directory at `/app/config`

## 3. Container Engine — Hindsight Env

- [x] 3.1 Update `buildEnv` for `hindsight` case: replace `DATABASE_URL` + `HINDSIGHT_BASE_URL` with full `HINDSIGHT_API_*` env var set (`HINDSIGHT_API_DATABASE_URL`, `HINDSIGHT_API_EMBEDDING_LITELLM_MODEL`, `HINDSIGHT_API_EMBEDDING_PROVIDER`, `HINDSIGHT_API_LITELLM_API_BASE`, `HINDSIGHT_API_LLM_BASE_URL`, `HINDSIGHT_API_LLM_MODEL`, `HINDSIGHT_API_LLM_PROVIDER`, `HINDSIGHT_API_PORT`, `HINDSIGHT_API_LLM_API_KEY`)
- [x] 3.2 Update `buildEnv` for `worker` case: replace `HINDSIGHT_BASE_URL` with `HINDSIGHT_URL=http://{hindsightIP}:8888/` and add `HINDSIGHT_BANK_ID=errand-tasks`, conditional on `config.useHindsight`
- [x] 3.3 Update Hindsight `ServiceInfo` definition in `AppState`: change `containerPort` from `8080` to `8888`
- [x] 3.4 Update `HealthChecker.checkAll` for `hindsight` case: change health check port from `8080` to `8888`
- [x] 3.5 Update `ContainerEngine` health check for `hindsight`: change port from `8080` to `8888`

## 4. Conditional Service Startup

- [x] 4.1 Update `ContainerEngine.startAll` to accept config and skip `litellm` when `config.useLiteLLM == false` and skip `hindsight` when `config.useHindsight == false`
- [x] 4.2 Update `buildEnv` for `backend` and `worker` cases to fall back to `config.openaiBaseURL` / `config.openaiAPIKey` when `serviceIPs["litellm"]` is nil (LiteLLM disabled)

## 5. AppState — Setup Services & Model Fetching

- [x] 5.1 Add `AppState.startSetupServices()` method that pulls and starts only Postgres + LiteLLM in order, with progress callbacks updating `services` array
- [x] 5.2 Set up port forwarding for LiteLLM in `startSetupServices()` so `localhost:{litellmPort}` works during setup
- [x] 5.3 Add `AppState.fetchAvailableModels()` method that calls `GET /v1/models` from the LLM base URL, parses the response, and returns chat and embedding model lists filtered by `mode`

## 6. Setup Wizard — Welcome & Structure

- [x] 6.1 Update `totalSteps` from 4 to 5 and adjust step index mapping (Welcome=0, LLM=1, Memory=2, Pull=3, Done=4)
- [x] 6.2 Update welcome step text from "Content Manager" to "Errand AI"

## 7. Setup Wizard — LLM Configuration Step

- [x] 7.1 Add "Use LiteLLM" toggle (bound to `config.useLiteLLM`, default on) at top of LLM step
- [x] 7.2 Add inline container startup UI: progress indicators for Postgres and LiteLLM (pulling → starting → running), triggered via `.task` when `useLiteLLM` is true
- [x] 7.3 Add "Open LiteLLM UI" button that opens `http://localhost:{litellmPort}/ui` in default browser, enabled only when LiteLLM is running
- [x] 7.4 Add Base URL and API Key fields with inline placeholder text (`prompt:` parameter), disabled when LiteLLM is on
- [x] 7.5 Add error handling: display error message with retry button if container startup fails, allow toggling LiteLLM off to proceed

## 8. Setup Wizard — Agent Memory Step

- [x] 8.1 Create `agentMemoryStep` view with "Use Hindsight for Agent Memory" toggle (bound to `config.useHindsight`, default on)
- [x] 8.2 Add model fetching on `.task` when step appears and Hindsight is enabled — call `fetchAvailableModels()`
- [x] 8.3 Add LLM Model `Picker` dropdown filtered to `mode=chat` models, auto-selecting first `claude-sonnet-*` match
- [x] 8.4 Add Embedding Model `Picker` dropdown filtered to `mode=embedding` models
- [x] 8.5 Disable both dropdowns when Hindsight toggle is off
- [x] 8.6 Add loading spinner and retry button for model fetch failures

## 9. Settings — LLM Tab

- [x] 9.1 Add "Use LiteLLM" toggle to LLM tab, reflecting `config.useLiteLLM`
- [x] 9.2 Disable Base URL and API Key fields when LiteLLM is on
- [x] 9.3 Replace external `LabeledContent` example text with inline placeholder text using `prompt:` parameter on `TextField`/`SecureField`

## 10. Settings — Memory Tab

- [x] 10.1 Add "Use Hindsight for Agent Memory" toggle, reflecting `config.useHindsight`
- [x] 10.2 Replace text fields with LLM Model and Embedding Model `Picker` dropdowns, populated by `fetchAvailableModels()`
- [x] 10.3 Disable both pickers when Hindsight toggle is off
- [x] 10.4 Pre-select current values from `config.hindsightLLMModel` and `config.hindsightEmbeddingModel`
