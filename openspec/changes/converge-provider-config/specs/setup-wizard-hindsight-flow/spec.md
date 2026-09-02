## REMOVED Requirements

### Requirement: Model dropdowns populated from LLM endpoint

**Reason**: The app no longer queries provider endpoints. Model lists come from the errand server, which already exposes them mode-filtered for every provider type. Replaced by "Memory model selection is served by the errand server".

### Requirement: LLM Model dropdown filtered by chat mode

**Reason**: Mode filtering is performed by the errand server for all provider types, including those whose listing does not report a mode. Replaced by "Memory model selection is served by the errand server".

### Requirement: Embedding Model dropdown filtered by embedding mode

**Reason**: Embeddings run in-process in the memory runtime image. There is no embedding model to select.

### Requirement: Model dropdowns disabled when Hindsight is off

**Reason**: There is a single model selector rather than a pair; its disabled behaviour is stated in the replacement requirement.

## ADDED Requirements

### Requirement: Memory model selection is served by the errand server

When memory is enabled, the Agent Memory step SHALL present a single model selector populated from the errand server's model listing for the selected provider, filtered to chat models. The app SHALL NOT contact the provider endpoint directly. Where the server reports that a provider does not support model listing, or listing fails, the step SHALL accept a directly entered model name.

#### Scenario: Models listed for a provider that supports listing

- **WHEN** memory is enabled and the selected provider supports model listing
- **THEN** chat models are presented for selection, as reported by the errand server

#### Scenario: Provider without model listing

- **WHEN** the errand server reports that the selected provider does not support model listing
- **THEN** a model name can be entered directly

#### Scenario: Listing fails

- **WHEN** model listing fails
- **THEN** direct entry is offered and the reason is explained

#### Scenario: Selector disabled when memory is off

- **WHEN** the memory toggle is off
- **THEN** the model selector is disabled and non-interactive

#### Scenario: Selection recorded

- **WHEN** the user selects or enters a model
- **THEN** it is recorded as the memory service's chat model

### Requirement: No embedding configuration is presented

The Agent Memory step SHALL NOT present any embedding provider or embedding model choice, and the Settings Memory tab SHALL NOT present one either. Embeddings are provided in-process by the memory runtime image and are not user-configurable from this app.

#### Scenario: Wizard omits embedding selection

- **WHEN** the user reaches the Agent Memory step with memory enabled
- **THEN** no embedding model or embedding provider control is displayed

#### Scenario: Settings omits embedding selection

- **WHEN** the user opens the Settings Memory tab
- **THEN** no embedding model or embedding provider control is displayed

## MODIFIED Requirements

### Requirement: Hindsight container environment variables
The Hindsight container SHALL receive LLM environment variables built from the errand server's provider data, with the API key supplied from the app's own storage or from a scoped LiteLLM service key. No embedding-related variables SHALL be set.

#### Scenario: Hindsight container starts with local LiteLLM
- **WHEN** the Hindsight container is started and `config.deployLiteLLM` is `true`
- **THEN** the LLM base URL points at the local LiteLLM proxy
- **THEN** the LLM API key is the scoped hindsight service key
- **THEN** the LLM provider is set for an OpenAI-compatible endpoint
- **THEN** no embeddings provider variable is set

#### Scenario: Hindsight container starts with external provider
- **WHEN** the Hindsight container is started and `config.deployLiteLLM` is `false`
- **THEN** the LLM base URL is the base URL the errand server reports for the selected provider
- **THEN** the LLM API key is the app's stored provider credential
- **THEN** the LLM provider is set for an OpenAI-compatible endpoint
- **THEN** no embeddings provider variable is set

### Requirement: Settings Memory tab mirrors wizard
The Settings Memory tab SHALL include a memory toggle and a single chat-model selector with the same behaviour as the Agent Memory step, sourced from the errand server.

#### Scenario: Model selectors adapt to provider type in settings
- **WHEN** the Settings Memory tab is opened and memory is enabled
- **THEN** the model selector is populated from the errand server, falling back to direct entry where listing is unsupported or fails

#### Scenario: Hindsight disabled in settings
- **WHEN** the memory toggle is off in Settings
- **THEN** the model selector is disabled and non-interactive
