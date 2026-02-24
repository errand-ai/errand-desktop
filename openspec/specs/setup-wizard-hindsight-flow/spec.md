## ADDED Requirements

### Requirement: Agent Memory step in setup wizard
The setup wizard SHALL include an Agent Memory step (step 3) with a "Use Hindsight for Agent Memory" toggle that defaults to on.

#### Scenario: User arrives at Agent Memory step
- **WHEN** the user navigates to the Agent Memory step
- **THEN** the "Use Hindsight for Agent Memory" toggle is on by default

#### Scenario: User opts out of Hindsight
- **WHEN** the user toggles "Use Hindsight for Agent Memory" off
- **THEN** `config.useHindsight` is set to `false`

### Requirement: Model dropdowns populated from LLM endpoint
When Hindsight is enabled, the Agent Memory step SHALL fetch available models from the LLM base URL (`GET /v1/models`) and populate two dropdown selectors.

#### Scenario: Models fetched successfully with LiteLLM enabled
- **WHEN** Hindsight is enabled and LiteLLM is running
- **THEN** the app calls `GET http://localhost:{litellmPort}/v1/models`
- **THEN** the response is parsed and models are separated by `mode` field

#### Scenario: Models fetched with LiteLLM disabled
- **WHEN** Hindsight is enabled and LiteLLM is disabled
- **THEN** the app calls `GET {config.openaiBaseURL}/models` with `config.openaiAPIKey` as bearer token

#### Scenario: Model fetch fails
- **WHEN** the model fetch request fails (network error, LiteLLM not ready)
- **THEN** the dropdowns are empty and a retry button is displayed

### Requirement: LLM Model dropdown filtered by chat mode
The LLM Model dropdown SHALL display only models where `mode` equals `chat`, with automatic selection of a Claude Sonnet model if available.

#### Scenario: Claude Sonnet model available
- **WHEN** the model list contains a model with `id` matching `claude-sonnet-*`
- **THEN** that model is auto-selected in the LLM Model dropdown

#### Scenario: No Claude Sonnet model available
- **WHEN** no model in the list matches `claude-sonnet-*`
- **THEN** no model is auto-selected and the user MUST choose manually

#### Scenario: User selects LLM model
- **WHEN** the user selects a model from the LLM Model dropdown
- **THEN** `config.hindsightLLMModel` is set to the selected model ID

### Requirement: Embedding Model dropdown filtered by embedding mode
The Embedding Model dropdown SHALL display only models where `mode` equals `embedding`.

#### Scenario: Embedding models available
- **WHEN** the model list contains models with `mode` equal to `embedding`
- **THEN** those models are displayed in the Embedding Model dropdown

#### Scenario: User selects embedding model
- **WHEN** the user selects a model from the Embedding Model dropdown
- **THEN** `config.hindsightEmbeddingModel` is set to the selected model ID

### Requirement: Model dropdowns disabled when Hindsight is off
Both model dropdowns SHALL be greyed out and non-interactive when Hindsight is disabled.

#### Scenario: Hindsight disabled disables dropdowns
- **WHEN** "Use Hindsight for Agent Memory" is toggled off
- **THEN** the LLM Model and Embedding Model dropdowns are greyed out and non-interactive

#### Scenario: Hindsight enabled enables dropdowns
- **WHEN** "Use Hindsight for Agent Memory" is toggled on
- **THEN** the LLM Model and Embedding Model dropdowns are enabled and interactive

### Requirement: Hindsight container environment variables
The Hindsight container SHALL receive the full set of `HINDSIGHT_API_*` environment variables at startup.

#### Scenario: Hindsight container starts with LiteLLM enabled
- **WHEN** the Hindsight container is started and `config.useLiteLLM` is `true`
- **THEN** the following environment variables are set: `HINDSIGHT_API_DATABASE_URL=postgresql://postgres:postgres@{postgresIP}:5432/hindsight`, `HINDSIGHT_API_EMBEDDING_LITELLM_MODEL={config.hindsightEmbeddingModel}`, `HINDSIGHT_API_EMBEDDING_PROVIDER=litellm`, `HINDSIGHT_API_LITELLM_API_BASE=http://{litellmIP}:{litellmPort}/v1`, `HINDSIGHT_API_LLM_BASE_URL=http://{litellmIP}:{litellmPort}/v1`, `HINDSIGHT_API_LLM_MODEL={config.hindsightLLMModel}`, `HINDSIGHT_API_LLM_PROVIDER=litellm`, `HINDSIGHT_API_PORT=8888`, `HINDSIGHT_API_LLM_API_KEY={litellmMasterKey}`

#### Scenario: Hindsight container starts with LiteLLM disabled
- **WHEN** the Hindsight container is started and `config.useLiteLLM` is `false`
- **THEN** `HINDSIGHT_API_LITELLM_API_BASE` and `HINDSIGHT_API_LLM_BASE_URL` are set to `config.openaiBaseURL`
- **THEN** `HINDSIGHT_API_LLM_API_KEY` is set to `config.openaiAPIKey`

### Requirement: Worker container Hindsight env vars
When `config.useHindsight` is true, the Worker container SHALL receive Hindsight connection environment variables.

#### Scenario: Hindsight enabled adds worker env vars
- **WHEN** `config.useHindsight` is `true` and the Hindsight container is running
- **THEN** the Worker container receives `HINDSIGHT_URL=http://{hindsightIP}:8888/` and `HINDSIGHT_BANK_ID=errand-tasks`

#### Scenario: Hindsight disabled omits worker env vars
- **WHEN** `config.useHindsight` is `false`
- **THEN** the Worker container does not receive `HINDSIGHT_URL` or `HINDSIGHT_BANK_ID`

### Requirement: Conditional Hindsight startup in full service startup
When `config.useHindsight` is false, the full service startup SHALL skip the Hindsight container.

#### Scenario: Hindsight disabled skips container
- **WHEN** `config.useHindsight` is `false` and the user starts all services
- **THEN** the Hindsight container is not pulled, created, or started

#### Scenario: Hindsight enabled starts container
- **WHEN** `config.useHindsight` is `true` and the user starts all services
- **THEN** the Hindsight container is pulled, created, and started as part of the normal startup order

### Requirement: Hindsight container port is 8888
The Hindsight container SHALL use port 8888 as its internal service port, matching `HINDSIGHT_API_PORT`.

#### Scenario: Health check uses port 8888
- **WHEN** the health checker monitors the Hindsight container
- **THEN** it performs HTTP health checks against port 8888

#### Scenario: Port forwarding uses correct container port
- **WHEN** port forwarding is configured for Hindsight
- **THEN** the container port is 8888 (forwarded from `config.hindsightPort` on localhost)

### Requirement: Settings Memory tab mirrors wizard
The Settings Memory tab SHALL include a "Use Hindsight" toggle and model dropdowns with the same behavior as the setup wizard Agent Memory step.

#### Scenario: Hindsight toggle in settings
- **WHEN** the user opens the Settings Memory tab
- **THEN** a "Use Hindsight for Agent Memory" toggle is displayed, reflecting `config.useHindsight`

#### Scenario: Model dropdowns in settings
- **WHEN** the Settings Memory tab is opened and Hindsight is enabled
- **THEN** LLM Model and Embedding Model dropdowns are populated by fetching from the LLM base URL
- **THEN** current values from `config.hindsightLLMModel` and `config.hindsightEmbeddingModel` are selected

#### Scenario: Hindsight disabled in settings
- **WHEN** "Use Hindsight" is off in Settings
- **THEN** the LLM Model and Embedding Model dropdowns are greyed out and non-interactive
