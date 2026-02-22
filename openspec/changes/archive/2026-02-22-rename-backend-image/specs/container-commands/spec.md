## MODIFIED Requirements

### Requirement: Ephemeral migrate container
A database migration container runs `alembic upgrade head` after Postgres is healthy and before the backend starts.

#### Scenario: Migration runs on startup
- **WHEN** services are starting and Postgres is healthy
- **THEN** a migrate container is created using the errand image with command `alembic upgrade head`
- **THEN** the system waits for the container to exit
- **THEN** on exit code 0, the container is cleaned up and startup proceeds

#### Scenario: Migration failure stops startup
- **WHEN** the migrate container exits with a non-zero exit code
- **THEN** startup is aborted with an error
- **THEN** the migrate container is cleaned up

#### Scenario: Migration runs concurrently with Valkey
- **WHEN** services are starting
- **THEN** the migrate container and Valkey container start in the same group (concurrently)
- **THEN** both must complete/be healthy before backend starts
