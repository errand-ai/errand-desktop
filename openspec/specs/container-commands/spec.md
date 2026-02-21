## ADDED Requirements

### Requirement: Custom container command override
Containers can be started with a custom command that overrides the image's default CMD.

#### Scenario: Worker starts with python worker.py
- **WHEN** the worker service is started
- **THEN** the container runs `python worker.py` instead of the image default CMD

#### Scenario: Backend uses default CMD
- **WHEN** the backend service is started
- **THEN** the container runs the image's default CMD (no override)

### Requirement: Ephemeral migrate container
A database migration container runs `alembic upgrade head` after Postgres is healthy and before the backend starts.

#### Scenario: Migration runs on startup
- **WHEN** services are starting and Postgres is healthy
- **THEN** a migrate container is created using the errand-backend image with command `alembic upgrade head`
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

### Requirement: Migrate service environment
The migrate container receives only the environment variables it needs.

#### Scenario: Migrate container env vars
- **WHEN** the migrate container is created
- **THEN** it receives `DATABASE_URL` pointing to the Postgres container IP

### Requirement: No AUTO_MIGRATE on backend
The backend no longer uses the AUTO_MIGRATE workaround since migrations are handled explicitly.

#### Scenario: Backend env excludes AUTO_MIGRATE
- **WHEN** the backend container is created
- **THEN** the `AUTO_MIGRATE` environment variable is NOT set
