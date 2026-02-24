## ADDED Requirements

### Requirement: Hindsight container lifecycle
The app SHALL pull, start, and stop the Hindsight container as part of the standard service lifecycle managed by `ContainerEngine`.

#### Scenario: Hindsight image pulled on startup
- **WHEN** services are starting
- **THEN** the image `ghcr.io/vectorize-io/hindsight:latest-slim` is pulled before the container is created

#### Scenario: Hindsight starts in group 2
- **WHEN** postgres and valkey are healthy
- **THEN** the hindsight container starts in the same group as migrate and litellm
- **THEN** backend does not start until hindsight is healthy

#### Scenario: Hindsight stops on shutdown
- **WHEN** services are stopping
- **THEN** the hindsight container is stopped in reverse startup order (after backend and worker have stopped)

### Requirement: Hindsight receives required environment variables
The hindsight container SHALL receive environment variables for database access, LLM routing, and model configuration.

#### Scenario: Hindsight env vars set
- **WHEN** the hindsight container is created
- **THEN** it receives `DATABASE_URL` pointing to the postgres container IP
- **THEN** it receives `LITELLM_BASE_URL` set to `http://<litellmIP>:4000`
- **THEN** it receives `HINDSIGHT_LLM_MODEL` from `AppConfig.hindsightLLMModel`
- **THEN** it receives `HINDSIGHT_EMBEDDING_MODEL` from `AppConfig.hindsightEmbeddingModel`

### Requirement: Hindsight data persisted via virtiofs share
The hindsight container SHALL have its data directory mounted from the host.

#### Scenario: Hindsight data directory mounted
- **WHEN** the hindsight container is created
- **THEN** `~/Library/Application Support/ErrandDesktop/data/hindsight` is mounted into the container at `/data`

#### Scenario: Hindsight data directory created on first run
- **WHEN** the app initialises storage for the first time
- **THEN** `~/Library/Application Support/ErrandDesktop/data/hindsight` is created

### Requirement: Hindsight health check via HTTP
The app SHALL poll Hindsight's HTTP health endpoint before marking the service healthy.

#### Scenario: Hindsight health check passes
- **WHEN** Hindsight is starting
- **THEN** the app polls `GET /health` at the hindsight container IP on port 8080
- **THEN** a 200 response marks the service as healthy

#### Scenario: Hindsight health check timeout
- **WHEN** Hindsight does not become healthy within 120 seconds
- **THEN** startup is aborted with a health check timeout error

### Requirement: Hindsight port forwarded to localhost
The app SHALL forward a configurable localhost port to the Hindsight container's port 8080.

#### Scenario: Hindsight port forwarded
- **WHEN** services have started and Hindsight has a container IP
- **THEN** `AppConfig.hindsightPort` (default 8081) is forwarded to the hindsight container IP on port 8080

### Requirement: Hindsight URL injected into backend and worker
The backend and worker containers SHALL receive Hindsight's internal URL so they can make requests to the memory service.

#### Scenario: Backend receives HINDSIGHT_BASE_URL
- **WHEN** the backend container is created and hindsight has a container IP
- **THEN** the backend receives `HINDSIGHT_BASE_URL` = `http://<hindsightIP>:8080`

#### Scenario: Worker receives HINDSIGHT_BASE_URL
- **WHEN** the worker container is created and hindsight has a container IP
- **THEN** the worker receives `HINDSIGHT_BASE_URL` = `http://<hindsightIP>:8080`

### Requirement: LiteLLM always deployed
LiteLLM SHALL be deployed as a standard always-on service regardless of user configuration.

#### Scenario: LiteLLM image updated
- **WHEN** the litellm container is created
- **THEN** the image `ghcr.io/berriai/litellm-database:main-v1.81.3-stable` is used

#### Scenario: LiteLLM receives database URL
- **WHEN** the litellm container is created
- **THEN** it receives `DATABASE_URL` pointing to the postgres container IP
- **THEN** it receives `LITELLM_MASTER_KEY` from a stable key stored in the macOS Keychain

#### Scenario: LiteLLM enabled toggle removed
- **WHEN** the user opens Settings
- **THEN** there is no "Enable LiteLLM" toggle

### Requirement: Memory settings tab replaces OIDC tab
The settings window SHALL provide a Memory tab for configuring Hindsight model names, replacing the OIDC tab.

#### Scenario: Memory tab visible in settings
- **WHEN** the user opens the Settings window
- **THEN** a "Memory" tab is visible
- **THEN** an "OIDC" tab is NOT present

#### Scenario: Memory tab allows LLM model configuration
- **WHEN** the user opens the Memory settings tab
- **THEN** a text field labelled "LLM Model" is shown bound to `AppConfig.hindsightLLMModel`
- **THEN** a text field labelled "Embedding Model" is shown bound to `AppConfig.hindsightEmbeddingModel`

#### Scenario: Memory settings saved
- **WHEN** the user edits model names and clicks Save
- **THEN** the values are persisted to `config.json` via `AppState.saveConfig()`
