## MODIFIED Requirements

### Requirement: LiteLLM is enabled by default in setup wizard
The LLM Configuration step SHALL offer three ways to reach models: adopting an AI runtime detected on this machine, choosing a provider from the catalog the errand server publishes, or the advanced option of deploying a local LiteLLM proxy. Deploying LiteLLM SHALL NOT be the default selection. A brief description SHALL explain the choice, with a link to https://errand.sh/docs/ai-models/ for more information.

#### Scenario: User arrives at LLM Configuration step
- **WHEN** the user navigates to the LLM Configuration step
- **THEN** "Deploy LiteLLM locally" is not selected by default
- **THEN** any AI runtime the errand server detected on this machine is offered for adoption
- **THEN** a catalog of hosted providers is offered, including an entry for an unlisted OpenAI-compatible provider
- **THEN** a "Learn more" link to https://errand.sh/docs/ai-models/ is displayed

#### Scenario: User chooses to deploy LiteLLM locally
- **WHEN** the user selects "Deploy LiteLLM locally"
- **THEN** `config.deployLiteLLM` is set to `true`
- **THEN** the provider selection and API key fields are hidden

#### Scenario: User chooses to connect to an existing provider
- **WHEN** the user selects a catalogued provider or the unlisted OpenAI-compatible entry
- **THEN** `config.deployLiteLLM` is set to `false`
- **THEN** the provider is created on the errand server with the supplied API key

### Requirement: Base URL and API Key fields conditional on LiteLLM toggle
A base URL field SHALL be shown only for the unlisted OpenAI-compatible entry; a catalogued provider SHALL require only an API key, taking its base URL from the catalog. No field SHALL be shown when LiteLLM is deployed locally.

#### Scenario: Local LiteLLM hides external provider fields
- **WHEN** "Deploy LiteLLM locally" is selected
- **THEN** no provider selection, base URL or API key field is displayed

#### Scenario: External provider shows fields with detection feedback
- **WHEN** a catalogued provider is selected and an API key entered, or the unlisted entry is selected and a base URL and API key entered
- **THEN** the provider is created on the errand server
- **AND** the provider type reported by the server is displayed

### Requirement: Settings LLM tab mirrors wizard
The Settings LLM tab SHALL offer the same three routes as the setup wizard, and SHALL display provider type and reachability as reported by the errand server rather than from locally derived state.

#### Scenario: LLM radio choice in settings
- **WHEN** the user opens the Settings LLM tab
- **THEN** the same three routes offered by the wizard are displayed, reflecting the current configuration

#### Scenario: External provider shows detection result in settings
- **WHEN** a provider is configured and the errand server reports its type
- **THEN** that type is displayed

#### Scenario: Changing URL or key in settings triggers re-detection
- **WHEN** the user modifies a provider base URL or API key in Settings
- **THEN** the change is sent to the errand server
- **AND** the provider type the server reports as a result is displayed
