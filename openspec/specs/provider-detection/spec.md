## Purpose
Defines how the app probes a configured LLM endpoint to identify its provider type, when detection re-runs, and how the result is persisted.

## Requirements

### Requirement: Provider type detection via HTTP probing
The system SHALL detect the type of an external LLM provider by probing its HTTP endpoints. Detection SHALL try LiteLLM first, then OpenAI-compatible, then fall back to unknown.

#### Scenario: LiteLLM provider detected
- **WHEN** the system probes a provider URL and `GET {base_url_without_v1}/model/info` returns HTTP 200 with a JSON body containing a `data` array
- **THEN** the provider type is set to `litellm`

#### Scenario: OpenAI-compatible provider detected
- **WHEN** the LiteLLM probe fails and `GET {base_url}/models` returns HTTP 200 with a JSON body containing a `data` array
- **THEN** the provider type is set to `openai_compatible`

#### Scenario: Unknown provider fallback
- **WHEN** both the LiteLLM and OpenAI-compatible probes fail (non-200 response, timeout, or unexpected body format)
- **THEN** the provider type is set to `unknown`

#### Scenario: v1 suffix stripped for LiteLLM probe
- **WHEN** the base URL ends with `/v1`
- **THEN** the LiteLLM probe sends to `{base_url_without_v1}/model/info` (e.g. `https://llm.example.com/model/info` for base URL `https://llm.example.com/v1`)

### Requirement: Detection includes authorization header
All detection probe requests SHALL include an `Authorization: Bearer {api_key}` header.

#### Scenario: Probe with API key
- **WHEN** the system probes a provider URL with an API key configured
- **THEN** each probe request includes the header `Authorization: Bearer {api_key}`

### Requirement: Detection timeout
Each detection probe SHALL time out after 10 seconds.

#### Scenario: Probe timeout
- **WHEN** a detection probe does not receive a response within 10 seconds
- **THEN** that probe is treated as failed and the next probe (or unknown fallback) is attempted

### Requirement: Detection results persisted
The detected provider type SHALL be persisted in `AppConfig.llmProviderType` and displayed in the UI without re-probing.

#### Scenario: Detection result saved to config
- **WHEN** provider detection completes
- **THEN** the result (`litellm`, `openai_compatible`, or `unknown`) is stored in `config.llmProviderType`

#### Scenario: Detection not re-run on app restart
- **WHEN** the app starts and `llmProviderType` is already set in config
- **THEN** the persisted type is used without re-probing

### Requirement: Re-detection on URL or API key change
Detection SHALL re-run when the user changes the provider base URL or API key.

#### Scenario: URL changed triggers re-detection
- **WHEN** the user modifies the provider base URL in the setup wizard or settings
- **THEN** provider detection runs again with the new URL and API key

#### Scenario: API key changed triggers re-detection
- **WHEN** the user modifies the provider API key in the setup wizard or settings
- **THEN** provider detection runs again with the current URL and new API key

### Requirement: Detection skipped for local LiteLLM
Provider detection SHALL NOT run when the user chooses to deploy LiteLLM locally.

#### Scenario: Local LiteLLM skips detection
- **WHEN** `deployLiteLLM` is true
- **THEN** provider type is set to `litellm` without running any HTTP probes
