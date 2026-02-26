## ADDED Requirements

### Requirement: Service key provisioning after LiteLLM healthy
The app SHALL generate two scoped LiteLLM virtual API keys via `POST /key/generate` after LiteLLM passes its health check, before any dependent service (Backend, Worker, Hindsight) starts.

#### Scenario: Keys generated on first startup
- **WHEN** LiteLLM passes its health check and no service keys exist in the Keychain
- **THEN** the app calls `POST /key/generate` with `key_alias: "errand-services"` and `key_alias: "hindsight-services"`
- **THEN** the app authenticates using the master key as Bearer token
- **THEN** the returned `key` values are stored in the macOS Keychain under accounts `litellm-errand-key` and `litellm-hindsight-key`

#### Scenario: Keys reused on subsequent startup
- **WHEN** LiteLLM passes its health check and service keys exist in the Keychain
- **THEN** the app validates the keys via `GET /key/info?key=<key>`
- **THEN** if both keys return a successful response, they are used without regeneration

#### Scenario: Stale key detected and regenerated
- **WHEN** a Keychain-stored key fails validation against LiteLLM (e.g. LiteLLM DB was reset)
- **THEN** the stale key is deleted from the Keychain
- **THEN** a new key is generated via `POST /key/generate` with the same alias
- **THEN** the new key is stored in the Keychain

#### Scenario: Provisioning runs in setup wizard path
- **WHEN** `startSetupServices()` completes and LiteLLM is healthy
- **THEN** service key provisioning runs before the user proceeds to the Agent Memory step

#### Scenario: Provisioning runs in normal startup path
- **WHEN** `startAll()` completes LiteLLM's health check
- **THEN** service key provisioning runs before Backend, Worker, or Hindsight env vars are built

### Requirement: LiteLLM API URL resolved by runtime
The HTTP calls to LiteLLM for key provisioning SHALL use the correct URL for the active container runtime.

#### Scenario: Docker runtime uses localhost
- **WHEN** the active runtime is Docker
- **THEN** key provisioning calls use `http://localhost:{config.litellmPort}`

#### Scenario: Apple Containerization uses container IP
- **WHEN** the active runtime is Apple Containerization
- **THEN** key provisioning calls use `http://{litellmContainerIP}:4000`

### Requirement: Errand service key injected into Backend and Worker
The Backend and Worker containers SHALL receive the errand service key as `OPENAI_API_KEY` instead of the master key when LiteLLM is enabled.

#### Scenario: Backend receives errand service key
- **WHEN** the Backend container is created and LiteLLM is enabled
- **THEN** `OPENAI_API_KEY` is set to the errand service key from the Keychain

#### Scenario: Worker receives errand service key
- **WHEN** the Worker container is created and LiteLLM is enabled
- **THEN** `OPENAI_API_KEY` is set to the errand service key from the Keychain

#### Scenario: Task runner inherits errand service key
- **WHEN** the Worker creates a task runner container via the Bridge API
- **THEN** the task runner receives the errand service key (passed through by the Worker's own `OPENAI_API_KEY`)

### Requirement: Hindsight service key injected into Hindsight container
The Hindsight container SHALL receive the hindsight service key for its LLM and embedding API calls instead of the master key.

#### Scenario: Hindsight receives hindsight service key
- **WHEN** the Hindsight container is created and LiteLLM is enabled
- **THEN** `HINDSIGHT_API_LLM_API_KEY` is set to the hindsight service key
- **THEN** `HINDSIGHT_API_EMBEDDINGS_LITELLM_API_KEY` is set to the hindsight service key

### Requirement: Master key unchanged for LiteLLM and host operations
The master key SHALL continue to be used for LiteLLM's own configuration and host-side admin operations.

#### Scenario: LiteLLM container keeps master key
- **WHEN** the LiteLLM container is created
- **THEN** `PROXY_MASTER_KEY` and `LITELLM_MASTER_KEY` are set to the master key (unchanged)

#### Scenario: Host model queries use master key
- **WHEN** the host app calls `fetchAvailableModels()` to populate UI dropdowns
- **THEN** the Bearer token is the master key

#### Scenario: LiteLLM UI login uses master key
- **WHEN** the BridgeServer handles a `/litellm-login` request
- **THEN** the login credentials use the master key (unchanged)

### Requirement: Graceful fallback on provisioning failure
If key provisioning fails (network error, LiteLLM not ready), the app SHALL fall back to using the master key and log a warning.

#### Scenario: Key generation HTTP call fails
- **WHEN** `POST /key/generate` returns an error or times out
- **THEN** the app logs a warning message
- **THEN** Backend, Worker, and Hindsight containers receive the master key as fallback
- **THEN** services start normally

### Requirement: Keys use default type with no restrictions
Generated keys SHALL use `key_type: "default"` with empty model lists (all models accessible) and no budget or rate limits.

#### Scenario: Key generation request body
- **WHEN** a service key is generated
- **THEN** the request body includes `key_alias`, `key_type: "default"`, `models: []`, and a `metadata` object identifying the key's purpose
