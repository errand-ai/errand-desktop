## MODIFIED Requirements

### Requirement: Hindsight receives required environment variables
The hindsight container SHALL receive environment variables for database access, LLM routing, and model configuration. The LLM endpoint, provider type and model SHALL be obtained from the errand server's provider data rather than derived locally. The API key SHALL come from the app's own stored credential, or from a scoped LiteLLM service key when a local LiteLLM proxy is deployed; it SHALL NOT be requested from the errand server. The container SHALL NOT receive embedding provider or embedding model configuration, because embeddings run in-process in the memory runtime image.

#### Scenario: Hindsight env vars set
- **WHEN** the hindsight container is created
- **THEN** it receives a database connection pointing at the shared database, with the memory service's own schema
- **THEN** it receives the LLM base URL reported by the errand server for the selected provider
- **THEN** it receives the LLM model selected through the errand server
- **THEN** it receives no embedding provider or embedding model variables

#### Scenario: Hindsight receives scoped service key
- **WHEN** the hindsight container is created and LiteLLM is enabled
- **THEN** the LLM API key is set to the hindsight service key (not the master key)
- **THEN** no embeddings API key variable is set, because embeddings do not call an external provider

#### Scenario: Hindsight receives direct API key when LiteLLM disabled
- **WHEN** the hindsight container is created and LiteLLM is disabled
- **THEN** the LLM API key is set from the app's stored provider credential
- **THEN** the key is taken from local storage and not read back from the errand server

## ADDED Requirements

### Requirement: Hindsight starts after the errand server

The hindsight container SHALL be started only after the errand server is running and its provider data is available, because its environment is derived from that data. The dependency SHALL be expressed in the service startup ordering.

#### Scenario: Ordering enforced

- **WHEN** services are started
- **THEN** the errand server reaches a healthy state before the hindsight container is created

#### Scenario: Restart while the server is unavailable

- **WHEN** the hindsight container is restarted and the errand server is not reachable
- **THEN** the app uses its last known provider values to rebuild the environment
- **AND** reports that the configuration may be stale rather than silently treating the cache as authoritative
