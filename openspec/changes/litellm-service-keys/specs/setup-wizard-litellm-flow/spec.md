## MODIFIED Requirements

### Requirement: Inline container startup when LiteLLM is enabled
When LiteLLM is enabled on the LLM Configuration step, the app SHALL pull and start the Postgres and LiteLLM containers inline, showing progress to the user. After LiteLLM is healthy, the app SHALL provision scoped service keys before the user proceeds.

#### Scenario: LiteLLM enabled triggers container startup
- **WHEN** the user is on the LLM Configuration step with "Use LiteLLM" toggled on
- **THEN** the app pulls the Postgres image, starts the Postgres container, waits for it to be healthy, then pulls the LiteLLM image, starts the LiteLLM container, and waits for it to be healthy
- **THEN** progress indicators show the current state (pulling, starting, running) for each service

#### Scenario: Service keys provisioned after LiteLLM healthy
- **WHEN** LiteLLM reaches the running state during the setup wizard
- **THEN** the app provisions errand and hindsight service keys via LiteLLM's `/key/generate` API
- **THEN** the keys are available before the user navigates to the Agent Memory step

#### Scenario: Container startup fails
- **WHEN** Postgres or LiteLLM fails to start during the LLM Configuration step
- **THEN** the app displays an error message with a retry button
- **THEN** the user can toggle LiteLLM off and proceed with manual configuration
