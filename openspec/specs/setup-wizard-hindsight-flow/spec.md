## Purpose
Defines the Agent Memory step of the setup wizard: how model dropdowns are populated and filtered from the LLM endpoint, and how the choices reach the Hindsight container and the Settings tab.

## Requirements

### Requirement: Agent Memory step in setup wizard
The setup wizard SHALL include an Agent Memory step with a "Use Hindsight for Agent Memory" toggle that defaults to on. A brief description SHALL explain that Hindsight provides persistent memory for AI agents, with a link to https://errand.sh/docs/ai-memory/ for more information.

#### Scenario: User arrives at Agent Memory step
- **WHEN** the user navigates to the Agent Memory step
- **THEN** the "Use Hindsight for Agent Memory" toggle is on by default
- **THEN** a brief description explains what Hindsight provides
- **THEN** a "Learn more" link to https://errand.sh/docs/ai-memory/ is displayed

#### Scenario: User opts out of Hindsight
- **WHEN** the user toggles "Use Hindsight for Agent Memory" off
- **THEN** `config.useHindsight` is set to `false`

### Requirement: Model dropdowns populated from LLM endpoint
When Hindsight is enabled, the Agent Memory step SHALL fetch available models from the configured LLM provider and populate two dropdown selectors. The fetch method SHALL depend on the provider type.

#### Scenario: Models fetched from local LiteLLM
- **WHEN** Hindsight is enabled and `config.deployLiteLLM` is true and LiteLLM is running
- **THEN** the app calls `GET http://localhost:{litellmPort}/model/info` with the master key as bearer token
- **THEN** the response is parsed and models are separated by `mode` field

#### Scenario: Models fetched from remote LiteLLM
- **WHEN** Hindsight is enabled and `config.llmProviderType` is `litellm`
- **THEN** the app calls `GET {base_url_without_v1}/model/info` with the provider API key as bearer token
- **THEN** the response is parsed and models are separated by `mode` field

#### Scenario: Models fetched from OpenAI-compatible provider
- **WHEN** Hindsight is enabled and `config.llmProviderType` is `openai_compatible`
- **THEN** the app calls `GET {config.llmProviderBaseURL}/models` with the provider API key as bearer token
- **THEN** all models are shown in both LLM and embedding dropdowns (no mode filtering)

#### Scenario: Unknown provider uses free text entry
- **WHEN** Hindsight is enabled and `config.llmProviderType` is `unknown`
- **THEN** both model selectors are free text input fields instead of dropdowns
- **THEN** the user types model names directly

#### Scenario: Model fetch fails
- **WHEN** the model fetch request fails (network error, provider not ready)
- **THEN** the dropdowns are empty and a retry button is displayed

### Requirement: LLM Model dropdown filtered by chat mode
The LLM Model dropdown SHALL display only models where `mode` equals `chat` when the provider type is `litellm`. For `openai_compatible` providers, all models SHALL be shown. For `unknown` providers, a free text field SHALL be used.

#### Scenario: LiteLLM provider filters by chat mode
- **WHEN** the provider type is `litellm` and the model list is populated
- **THEN** only models with `mode` equal to `chat` are shown in the LLM Model dropdown

#### Scenario: Claude Sonnet model available
- **WHEN** the model list contains a model with `id` matching `claude-sonnet-*`
- **THEN** that model is auto-selected in the LLM Model dropdown

#### Scenario: No Claude Sonnet model available
- **WHEN** no model in the list matches `claude-sonnet-*`
- **THEN** no model is auto-selected and the user MUST choose manually

#### Scenario: OpenAI-compatible provider shows all models
- **WHEN** the provider type is `openai_compatible`
- **THEN** all models from the `/models` response are shown in the LLM Model dropdown

#### Scenario: Unknown provider shows free text
- **WHEN** the provider type is `unknown`
- **THEN** a free text input field is shown instead of a dropdown

#### Scenario: User selects or enters LLM model
- **WHEN** the user selects a model from the dropdown or enters a model name in the text field
- **THEN** `config.hindsightLLMModel` is set to the selected or entered model name

### Requirement: Embedding Model dropdown filtered by embedding mode
The Embedding Model dropdown SHALL display only models where `mode` equals `embedding` when the provider type is `litellm`. For `openai_compatible` providers, all models SHALL be shown. For `unknown` providers, a free text field SHALL be used.

#### Scenario: LiteLLM provider filters by embedding mode
- **WHEN** the provider type is `litellm` and the model list is populated
- **THEN** only models with `mode` equal to `embedding` are shown in the Embedding Model dropdown

#### Scenario: OpenAI-compatible provider shows all models
- **WHEN** the provider type is `openai_compatible`
- **THEN** all models from the `/models` response are shown in the Embedding Model dropdown

#### Scenario: Unknown provider shows free text
- **WHEN** the provider type is `unknown`
- **THEN** a free text input field is shown instead of a dropdown

#### Scenario: User selects or enters embedding model
- **WHEN** the user selects a model from the dropdown or enters a model name in the text field
- **THEN** `config.hindsightEmbeddingModel` is set to the selected or entered model name

### Requirement: Model dropdowns disabled when Hindsight is off
Both model selectors (dropdown or free text) SHALL be greyed out and non-interactive when Hindsight is disabled.

#### Scenario: Hindsight disabled disables model selectors
- **WHEN** "Use Hindsight for Agent Memory" is toggled off
- **THEN** the LLM Model and Embedding Model selectors are greyed out and non-interactive

#### Scenario: Hindsight enabled enables model selectors
- **WHEN** "Use Hindsight for Agent Memory" is toggled on
- **THEN** the LLM Model and Embedding Model selectors are enabled and interactive

### Requirement: Hindsight container environment variables
The Hindsight container SHALL receive `HINDSIGHT_API_*` environment variables using the configured provider's connection details.

#### Scenario: Hindsight container starts with local LiteLLM
- **WHEN** the Hindsight container is started and `config.deployLiteLLM` is `true`
- **THEN** `HINDSIGHT_API_LLM_BASE_URL` is set to `http://{litellmIP}:4000/v1`
- **THEN** `HINDSIGHT_API_LLM_API_KEY` is set to the scoped `hindsightServiceKey`
- **THEN** `HINDSIGHT_API_LLM_PROVIDER` is set to `litellm`
- **THEN** `HINDSIGHT_API_EMBEDDINGS_PROVIDER` is set to `litellm`

#### Scenario: Hindsight container starts with external provider
- **WHEN** the Hindsight container is started and `config.deployLiteLLM` is `false`
- **THEN** `HINDSIGHT_API_LLM_BASE_URL` is set to `config.llmProviderBaseURL`
- **THEN** `HINDSIGHT_API_LLM_API_KEY` is set to `config.llmProviderAPIKey`
- **THEN** `HINDSIGHT_API_LLM_PROVIDER` is set to `openai`
- **THEN** `HINDSIGHT_API_EMBEDDINGS_PROVIDER` is set to `openai`

### Requirement: Settings Memory tab mirrors wizard
The Settings Memory tab SHALL include a "Use Hindsight" toggle and model selectors with the same adaptive behavior as the setup wizard Agent Memory step.

#### Scenario: Model selectors adapt to provider type in settings
- **WHEN** the Settings Memory tab is opened and Hindsight is enabled
- **THEN** model selectors use dropdowns for `litellm`/`openai_compatible` providers and free text for `unknown` providers
- **THEN** current values from `config.hindsightLLMModel` and `config.hindsightEmbeddingModel` are shown

#### Scenario: Hindsight disabled in settings
- **WHEN** "Use Hindsight" is off in Settings
- **THEN** the model selectors are greyed out and non-interactive
