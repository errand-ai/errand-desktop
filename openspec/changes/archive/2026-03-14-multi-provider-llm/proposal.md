## Why

The errand-server now supports multiple LLM providers via indexed environment variables (`LLM_PROVIDER_N_*`) instead of a single `OPENAI_BASE_URL`/`OPENAI_API_KEY`. The desktop app needs to align with this, giving users the choice to deploy LiteLLM locally (recommended) or connect to an external provider (remote LiteLLM, OpenAI-compatible API, or other). The desktop app passes a single provider configuration to the errand-server containers using the new env var format.

## What Changes

- **BREAKING**: Replace `openaiBaseURL`, `openaiAPIKey`, and `useLiteLLM` config fields with `deployLiteLLM`, `llmProviderName`, `llmProviderBaseURL`, `llmProviderAPIKey`, and `llmProviderType`
- **BREAKING**: Replace `OPENAI_BASE_URL`/`OPENAI_API_KEY` env var injection to backend/worker with `LLM_PROVIDER_0_NAME`, `LLM_PROVIDER_0_BASE_URL`, `LLM_PROVIDER_0_API_KEY`
- Redesign setup wizard LLM step: radio choice between deploying LiteLLM locally or connecting to an external provider with name, base URL, and API key fields
- Add provider type detection for external providers (probe for LiteLLM `/model/info`, then OpenAI-compatible `/models`, else unknown)
- Adapt Hindsight model selection: dropdown for litellm/openai_compatible providers, free text entry for unknown providers
- Add brief descriptions and documentation links to the LLM choice step (errand.sh/docs/ai-models/) and Hindsight step (errand.sh/docs/ai-memory/)
- Redesign settings LLM tab to match the new wizard layout with persisted detection results

## Capabilities

### New Capabilities

- `provider-detection`: Probe an external provider URL to determine its type (litellm, openai_compatible, unknown) and whether it supports model listing

### Modified Capabilities

- `setup-wizard-litellm-flow`: Replace the LiteLLM toggle with a radio choice between local LiteLLM deployment and external provider connection; add provider name field, detection feedback, and documentation link
- `setup-wizard-hindsight-flow`: Adapt model selection to provider type (dropdown vs free text); add brief description and documentation link

## Impact

- **AppConfig**: New fields replace old ones (no migration needed — no existing users)
- **ContainerEngine.buildEnv**: Backend and worker env var injection changes from `OPENAI_*` to `LLM_PROVIDER_0_*`; Hindsight env vars unchanged
- **SetupAssistantView**: LLM step UI redesign; Hindsight step model selection adaptation
- **SettingsView**: LLM tab redesign to mirror new wizard layout
- **AppState**: Model fetching adapts to provider type (use `/model/info` for litellm, `/models` for openai_compatible, skip for unknown)
- **New code**: Provider detection logic (Swift, URLSession-based probing)
