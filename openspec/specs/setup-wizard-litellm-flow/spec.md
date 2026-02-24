## ADDED Requirements

### Requirement: Welcome screen displays correct product name
The welcome step SHALL display "This app runs the Errand AI stack locally" instead of "This app runs the Content Manager stack locally".

#### Scenario: User sees correct product name on welcome screen
- **WHEN** the setup wizard opens on the Welcome step
- **THEN** the description text reads "This app runs the Errand AI stack locally using lightweight Linux containers on your Mac."

### Requirement: LiteLLM is enabled by default in setup wizard
The LLM Configuration step SHALL display a "Use LiteLLM" toggle that defaults to on (enabled).

#### Scenario: User arrives at LLM Configuration step
- **WHEN** the user navigates to the LLM Configuration step
- **THEN** the "Use LiteLLM" toggle is on by default

#### Scenario: User opts out of LiteLLM
- **WHEN** the user toggles "Use LiteLLM" off
- **THEN** `config.useLiteLLM` is set to `false`

### Requirement: Inline container startup when LiteLLM is enabled
When LiteLLM is enabled on the LLM Configuration step, the app SHALL pull and start the Postgres and LiteLLM containers inline, showing progress to the user.

#### Scenario: LiteLLM enabled triggers container startup
- **WHEN** the user is on the LLM Configuration step with "Use LiteLLM" toggled on
- **THEN** the app pulls the Postgres image, starts the Postgres container, waits for it to be healthy, then pulls the LiteLLM image, starts the LiteLLM container, and waits for it to be healthy
- **THEN** progress indicators show the current state (pulling, starting, running) for each service

#### Scenario: Container startup fails
- **WHEN** Postgres or LiteLLM fails to start during the LLM Configuration step
- **THEN** the app displays an error message with a retry button
- **THEN** the user can toggle LiteLLM off and proceed with manual configuration

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

### Requirement: Base URL and API Key fields conditional on LiteLLM toggle
The Base URL and API Key fields SHALL be disabled when LiteLLM is enabled and editable when LiteLLM is disabled.

#### Scenario: LiteLLM enabled disables manual fields
- **WHEN** "Use LiteLLM" is toggled on
- **THEN** the Base URL and API Key text fields are greyed out and non-editable

#### Scenario: LiteLLM disabled enables manual fields
- **WHEN** "Use LiteLLM" is toggled off
- **THEN** the Base URL and API Key text fields are editable

### Requirement: Placeholder text inside text fields
The Base URL and API Key fields SHALL use inline placeholder text that disappears when the user starts typing, rather than external example labels.

#### Scenario: Empty Base URL field shows placeholder
- **WHEN** the Base URL field is empty and not focused
- **THEN** the field displays greyed-out placeholder text "https://api.openai.com/v1"

#### Scenario: Empty API Key field shows placeholder
- **WHEN** the API Key field is empty and not focused
- **THEN** the field displays greyed-out placeholder text "sk-...."

#### Scenario: User types in field
- **WHEN** the user begins typing in the Base URL or API Key field
- **THEN** the placeholder text disappears and is replaced by the user's input

### Requirement: LiteLLM master key format
The LiteLLM master key SHALL be generated in the format `sk-` followed by 18 random alphanumeric characters (upper and lowercase letters and digits), stored in the macOS Keychain.

#### Scenario: First-time key generation
- **WHEN** no LiteLLM master key exists in the Keychain (account `litellm-master-key`)
- **THEN** a new key is generated matching the pattern `sk-[a-zA-Z0-9]{18}`
- **THEN** the key is stored in the Keychain under account `litellm-master-key`

#### Scenario: Existing key retrieval
- **WHEN** a LiteLLM master key already exists in the Keychain
- **THEN** the existing key is returned without regeneration

### Requirement: LiteLLM container environment variables
The LiteLLM container SHALL receive the full set of required environment variables at startup.

#### Scenario: LiteLLM container starts with correct env vars
- **WHEN** the LiteLLM container is started
- **THEN** the following environment variables are set: `HOST=0.0.0.0`, `PORT=4000`, `DATABASE_USERNAME=postgres`, `DATABASE_PASSWORD=postgres`, `DATABASE_HOST={postgresIP}`, `DATABASE_NAME=litellm`, `DATABASE_URL=postgresql://postgres:postgres@{postgresIP}:5432/litellm`, `PROXY_MASTER_KEY={litellmMasterKey}`, `LITELLM_MODE=PRODUCTION`, `LITELLM_PROXY_CONNECTION_TIMEOUT=600`

### Requirement: LiteLLM config mount path
The LiteLLM container SHALL mount its configuration file at `/etc/litellm/config.yaml`.

#### Scenario: Config file is mounted correctly
- **WHEN** the LiteLLM container is created
- **THEN** the host config file is mounted as a single file at `/etc/litellm/config.yaml` inside the container

### Requirement: Conditional LiteLLM startup in full service startup
When `config.useLiteLLM` is false, the full service startup SHALL skip the LiteLLM container.

#### Scenario: LiteLLM disabled skips container
- **WHEN** `config.useLiteLLM` is `false` and the user starts all services
- **THEN** the LiteLLM container is not pulled, created, or started

#### Scenario: LiteLLM disabled falls back to direct config
- **WHEN** `config.useLiteLLM` is `false` and Backend/Worker containers start
- **THEN** the Backend and Worker containers receive `OPENAI_BASE_URL` from `config.openaiBaseURL` and `OPENAI_API_KEY` from `config.openaiAPIKey`

### Requirement: Settings LLM tab mirrors wizard
The Settings LLM tab SHALL include a "Use LiteLLM" toggle with the same conditional field behavior as the setup wizard.

#### Scenario: LiteLLM toggle in settings
- **WHEN** the user opens the Settings LLM tab
- **THEN** a "Use LiteLLM" toggle is displayed, reflecting `config.useLiteLLM`

#### Scenario: Toggle on disables fields in settings
- **WHEN** "Use LiteLLM" is on in Settings
- **THEN** the Base URL and API Key fields are greyed out and non-editable

#### Scenario: Toggle off enables fields in settings
- **WHEN** "Use LiteLLM" is off in Settings
- **THEN** the Base URL and API Key fields are editable with inline placeholder text

### Requirement: Setup wizard has 5 steps
The setup wizard SHALL have 5 steps: Welcome, LLM Configuration, Agent Memory, Image Pull, and Done.

#### Scenario: Step indicator shows 5 dots
- **WHEN** the setup wizard is displayed
- **THEN** the step indicator shows 5 dots corresponding to the 5 steps
