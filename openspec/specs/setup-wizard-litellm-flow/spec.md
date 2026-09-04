## Purpose
Defines the LLM step of the setup wizard: the LiteLLM toggle and its conditional fields, inline container startup, indexed provider env vars, and how Settings mirrors the wizard.

## Requirements

### Requirement: LiteLLM is enabled by default in setup wizard
The LLM Configuration step SHALL display a radio choice between "Deploy LiteLLM locally" (selected by default, recommended) and "Connect to an existing provider". A brief description SHALL explain the choice, with a link to https://errand.sh/docs/ai-models/ for more information.

#### Scenario: User arrives at LLM Configuration step
- **WHEN** the user navigates to the LLM Configuration step
- **THEN** "Deploy LiteLLM locally" is selected by default
- **THEN** a brief description explains that LiteLLM proxies requests to multiple AI providers for flexibility
- **THEN** a "Learn more" link to https://errand.sh/docs/ai-models/ is displayed

#### Scenario: User chooses to deploy LiteLLM locally
- **WHEN** the user selects "Deploy LiteLLM locally"
- **THEN** `config.deployLiteLLM` is set to `true`
- **THEN** the provider name, base URL, and API key fields are hidden

#### Scenario: User chooses to connect to an existing provider
- **WHEN** the user selects "Connect to an existing provider"
- **THEN** `config.deployLiteLLM` is set to `false`
- **THEN** provider name, base URL, and API key fields are shown and editable

### Requirement: Base URL and API Key fields conditional on LiteLLM toggle
The provider name, base URL, and API key fields SHALL be visible and editable only when "Connect to an existing provider" is selected.

#### Scenario: Local LiteLLM hides external provider fields
- **WHEN** "Deploy LiteLLM locally" is selected
- **THEN** the provider name, base URL, and API key fields are not displayed

#### Scenario: External provider shows fields with detection feedback
- **WHEN** "Connect to an existing provider" is selected and the user has entered a base URL and API key
- **THEN** provider detection runs and the result is displayed (e.g. "Detected: LiteLLM", "Detected: OpenAI-compatible", or "Detected: Unknown provider")

### Requirement: Placeholder text inside text fields
The Base URL and API Key fields SHALL use inline placeholder text that disappears when the user starts typing.

#### Scenario: Empty Base URL field shows placeholder
- **WHEN** the Base URL field is empty and not focused
- **THEN** the field displays greyed-out placeholder text "https://api.openai.com/v1"

#### Scenario: Empty API Key field shows placeholder
- **WHEN** the API Key field is empty and not focused
- **THEN** the field displays greyed-out placeholder text "sk-...."

#### Scenario: Empty Provider Name field shows placeholder
- **WHEN** the Provider Name field is empty and not focused
- **THEN** the field displays greyed-out placeholder text "e.g. OpenAI, Ollama"

#### Scenario: User types in field
- **WHEN** the user begins typing in any provider field
- **THEN** the placeholder text disappears and is replaced by the user's input

### Requirement: Inline container startup when LiteLLM is enabled
When LiteLLM is enabled on the LLM Configuration step, the app SHALL pull and start the Postgres and LiteLLM containers inline, showing progress to the user.

#### Scenario: LiteLLM enabled triggers container startup
- **WHEN** the user is on the LLM Configuration step with "Deploy LiteLLM locally" selected
- **THEN** the app pulls the Postgres image, starts the Postgres container, waits for it to be healthy, then pulls the LiteLLM image, starts the LiteLLM container, and waits for it to be healthy
- **THEN** progress indicators show the current state (pulling, starting, running) for each service

#### Scenario: Container startup fails
- **WHEN** Postgres or LiteLLM fails to start during the LLM Configuration step
- **THEN** the app displays an error message with a retry button
- **THEN** the user can switch to "Connect to an existing provider" and proceed

### Requirement: Open LiteLLM UI button
When LiteLLM is running, the LLM Configuration step SHALL display a button to open the LiteLLM UI in the user's default browser.

#### Scenario: LiteLLM is running
- **WHEN** the LiteLLM container reaches the running state during setup
- **THEN** an "Open LiteLLM UI" button becomes enabled

#### Scenario: User clicks Open LiteLLM UI
- **WHEN** the user clicks the "Open LiteLLM UI" button
- **THEN** the system opens `http://localhost:{litellmPort}/ui` in the default browser

#### Scenario: LiteLLM is not yet running
- **WHEN** the LiteLLM container has not yet reached the running state
- **THEN** the "Open LiteLLM UI" button is disabled

### Requirement: Conditional LiteLLM startup in full service startup
When `config.deployLiteLLM` is false, the full service startup SHALL skip the LiteLLM container.

#### Scenario: LiteLLM disabled skips container
- **WHEN** `config.deployLiteLLM` is `false` and the user starts all services
- **THEN** the LiteLLM container is not pulled, created, or started

#### Scenario: External provider env vars injected
- **WHEN** `config.deployLiteLLM` is `false` and Backend/Worker containers start
- **THEN** the Backend and Worker containers receive `LLM_PROVIDER_0_NAME` from `config.llmProviderName`, `LLM_PROVIDER_0_BASE_URL` from `config.llmProviderBaseURL`, and `LLM_PROVIDER_0_API_KEY` from `config.llmProviderAPIKey`

### Requirement: Local LiteLLM env vars use indexed format
When `config.deployLiteLLM` is true, the Backend and Worker containers SHALL receive the local LiteLLM connection via indexed provider env vars with the scoped service key.

#### Scenario: Local LiteLLM env vars injected
- **WHEN** `config.deployLiteLLM` is `true` and Backend/Worker containers start
- **THEN** the containers receive `LLM_PROVIDER_0_NAME=LiteLLM`, `LLM_PROVIDER_0_BASE_URL=http://{litellmContainerIP}:4000/v1`, and `LLM_PROVIDER_0_API_KEY={errandServiceKey}`

### Requirement: Settings LLM tab mirrors wizard
The Settings LLM tab SHALL include the same radio choice and conditional field behavior as the setup wizard, with persisted detection results shown.

#### Scenario: LLM radio choice in settings
- **WHEN** the user opens the Settings LLM tab
- **THEN** a radio choice is displayed reflecting the current `config.deployLiteLLM` state

#### Scenario: External provider shows detection result in settings
- **WHEN** "Connect to an existing provider" is selected in Settings and a provider type has been detected
- **THEN** the persisted detection result is displayed (e.g. "Detected: OpenAI-compatible")

#### Scenario: Changing URL or key in settings triggers re-detection
- **WHEN** the user modifies the base URL or API key in Settings
- **THEN** provider detection re-runs and the displayed result updates

### Requirement: Setup wizard step count
The setup wizard SHALL have the same number of steps as currently, with the LLM step redesigned in place.

#### Scenario: Step indicator reflects current flow
- **WHEN** the setup wizard is displayed
- **THEN** the step indicator reflects the total steps, hiding the LiteLLM startup step when deploying locally is not selected
