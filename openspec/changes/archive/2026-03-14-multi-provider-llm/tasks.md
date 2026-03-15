## 1. AppConfig Changes

- [x] 1.1 Replace `openaiBaseURL`, `openaiAPIKey`, `useLiteLLM` fields with `deployLiteLLM` (Bool, default true), `llmProviderName` (String), `llmProviderBaseURL` (String), `llmProviderAPIKey` (String), `llmProviderType` (String, default empty)
- [x] 1.2 Remove any references to old field names throughout the codebase

## 2. Provider Detection

- [x] 2.1 Create `ProviderDetector` (or similar) with an async method that takes a base URL and API key, probes LiteLLM (`/model/info`) then OpenAI-compatible (`/models`), returns `litellm`, `openai_compatible`, or `unknown`
- [x] 2.2 Strip `/v1` suffix from base URL before the LiteLLM probe; include `Authorization: Bearer {api_key}` header; 10-second timeout per probe
- [x] 2.3 Integrate detection into setup wizard — run after user enters base URL and API key, display result (e.g. "Detected: OpenAI-compatible")
- [x] 2.4 Integrate detection into settings — re-run when URL or API key changes, display persisted result

## 3. Setup Wizard LLM Step Redesign

- [x] 3.1 Replace the `useLiteLLM` toggle with a radio choice: "Deploy LiteLLM locally" (default, recommended) and "Connect to an existing provider"
- [x] 3.2 Add brief description text explaining LiteLLM's role and a "Learn more" link to https://errand.sh/docs/ai-models/
- [x] 3.3 Show provider name, base URL, and API key fields only when "Connect to an existing provider" is selected; add placeholder text ("e.g. OpenAI, Ollama", "https://api.openai.com/v1", "sk-....")
- [x] 3.4 Show detection result feedback below the fields after probing completes
- [x] 3.5 Update step skip logic: skip LiteLLM startup step when "Connect to an existing provider" is selected (same pattern as current LiteLLM-off skip)

## 4. Setup Wizard Hindsight Step Updates

- [x] 4.1 Add brief description of Hindsight and a "Learn more" link to https://errand.sh/docs/ai-memory/
- [x] 4.2 Adapt model selection based on provider type: dropdown for `litellm`/`openai_compatible`, free text for `unknown`
- [x] 4.3 Update model fetching: use `/model/info` for litellm providers (with mode filtering), `/models` for openai_compatible (no mode filtering), skip fetch for unknown
- [x] 4.4 Ensure auto-selection of `claude-sonnet-*` still works when models are available

## 5. Settings LLM Tab Redesign

- [x] 5.1 Replace the `useLiteLLM` toggle and single base URL/API key fields with the radio choice and conditional provider fields matching the wizard
- [x] 5.2 Display persisted detection result; trigger re-detection on URL or API key change
- [x] 5.3 Ensure settings save updates `config.deployLiteLLM`, `llmProviderName`, `llmProviderBaseURL`, `llmProviderAPIKey`, `llmProviderType`

## 6. Settings Memory Tab Updates

- [x] 6.1 Adapt model selectors to provider type: dropdown for `litellm`/`openai_compatible`, free text for `unknown`
- [x] 6.2 Update model fetching logic to match the wizard (same endpoint selection by provider type)

## 7. Env Var Injection (ContainerEngine.buildEnv)

- [x] 7.1 Replace `OPENAI_BASE_URL`/`OPENAI_API_KEY` for backend container with `LLM_PROVIDER_0_NAME`, `LLM_PROVIDER_0_BASE_URL`, `LLM_PROVIDER_0_API_KEY`
- [x] 7.2 Replace `OPENAI_BASE_URL`/`OPENAI_API_KEY` for worker container with `LLM_PROVIDER_0_NAME`, `LLM_PROVIDER_0_BASE_URL`, `LLM_PROVIDER_0_API_KEY`
- [x] 7.3 For local LiteLLM: use `errandServiceKey` as the API key, `http://{litellmIP}:4000/v1` as base URL, "LiteLLM" as name
- [x] 7.4 For external provider: use `config.llmProviderAPIKey`, `config.llmProviderBaseURL`, `config.llmProviderName`
- [x] 7.5 Update Hindsight env vars: use `config.llmProviderBaseURL` and scoped key (local) or `config.llmProviderAPIKey` (external) for `HINDSIGHT_API_LLM_BASE_URL` and `HINDSIGHT_API_LLM_API_KEY`; set provider to `litellm` or `openai` based on `deployLiteLLM`

## 8. Service Lifecycle

- [x] 8.1 Update conditional LiteLLM startup to check `config.deployLiteLLM` instead of `config.useLiteLLM`
- [x] 8.2 Update any other references to `useLiteLLM` in service startup/shutdown logic

## 9. Testing

- [x] 9.1 Manual test: setup wizard with "Deploy LiteLLM locally" — verify full flow including container startup, model fetching, Hindsight configuration
- [x] 9.2 Manual test: setup wizard with "Connect to an existing provider" using an OpenAI-compatible endpoint — verify detection, model dropdown, env var injection
- [x] 9.3 Manual test: setup wizard with "Connect to an existing provider" using an unknown provider — verify detection fallback, free text model entry
- [x] 9.4 Manual test: settings page — verify radio choice, detection result display, re-detection on change, model selector adaptation
- [x] 9.5 Manual test: verify backend and worker containers receive `LLM_PROVIDER_0_*` env vars in both deployment modes
