## Purpose
Defines the environment the Hindsight memory service requires from the host app in order to start.

## Requirements

### Requirement: Hindsight receives required environment variables
The hindsight container SHALL receive environment variables for database access, LLM routing, and model configuration. LLM API keys SHALL be scoped hindsight service keys rather than the LiteLLM master key.

#### Scenario: Hindsight env vars set
- **WHEN** the hindsight container is created
- **THEN** it receives `DATABASE_URL` pointing to the postgres container IP
- **THEN** it receives `LITELLM_BASE_URL` set to `http://<litellmIP>:4000`
- **THEN** it receives `HINDSIGHT_LLM_MODEL` from `AppConfig.hindsightLLMModel`
- **THEN** it receives `HINDSIGHT_EMBEDDING_MODEL` from `AppConfig.hindsightEmbeddingModel`

#### Scenario: Hindsight receives scoped service key
- **WHEN** the hindsight container is created and LiteLLM is enabled
- **THEN** `HINDSIGHT_API_LLM_API_KEY` is set to the hindsight service key (not the master key)
- **THEN** `HINDSIGHT_API_EMBEDDINGS_LITELLM_API_KEY` is set to the hindsight service key (not the master key)

#### Scenario: Hindsight receives direct API key when LiteLLM disabled
- **WHEN** the hindsight container is created and LiteLLM is disabled
- **THEN** `HINDSIGHT_API_LLM_API_KEY` is set to `config.openaiAPIKey` (unchanged behavior)
- **THEN** `HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY` is set to `config.openaiAPIKey` (unchanged behavior)
