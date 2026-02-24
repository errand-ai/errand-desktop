## MODIFIED Requirements

### Requirement: Migration runs concurrently with LiteLLM and Hindsight
A database migration container runs `alembic upgrade head` after Postgres and Valkey are healthy and before the backend starts.

#### Scenario: Migration runs on startup
- **WHEN** services are starting and Postgres is healthy
- **THEN** a migrate container is created using the errand image with command `alembic upgrade head`
- **THEN** the system waits for the container to exit
- **THEN** on exit code 0, the container is cleaned up and startup proceeds

#### Scenario: Migration failure stops startup
- **WHEN** the migrate container exits with a non-zero exit code
- **THEN** startup is aborted with an error
- **THEN** the migrate container is cleaned up

#### Scenario: Migration runs concurrently with LiteLLM and Hindsight
- **WHEN** services are starting
- **THEN** the migrate container, LiteLLM container, and Hindsight container start in the same group (concurrently)
- **THEN** all three must complete/be healthy before backend starts

#### Scenario: Postgres and Valkey start in parallel
- **WHEN** services are starting
- **THEN** the postgres container and valkey container start in the same group (concurrently)
- **THEN** both must be healthy before migrate, litellm, and hindsight start
