## ADDED Requirements

### Requirement: Docker Engine API client
The system SHALL communicate with the Docker Engine via its HTTP REST API over the Unix socket at `/var/run/docker.sock`.

#### Scenario: API connection
- **WHEN** the Docker runtime initializes
- **THEN** it connects to the Docker Engine API via `/var/run/docker.sock`
- **THEN** it verifies connectivity by calling `GET /_ping`

#### Scenario: Docker not running
- **WHEN** the Docker runtime attempts to connect and the socket is not available
- **THEN** it reports a clear error indicating Docker Desktop is not running

### Requirement: Docker container lifecycle
The system SHALL manage Docker containers through the standard Docker API endpoints for create, start, stop, and remove.

#### Scenario: Create and start a container
- **WHEN** a service needs to start
- **THEN** the runtime calls `POST /containers/create` with the image, env vars, port bindings, volume mounts, and network config
- **THEN** it calls `POST /containers/{id}/start`

#### Scenario: Stop a container
- **WHEN** a service needs to stop
- **THEN** the runtime calls `POST /containers/{id}/stop` with a timeout
- **THEN** it calls `DELETE /containers/{id}` to remove the container

### Requirement: Docker port publishing
The system SHALL use Docker's native port publishing (`-p` flag equivalent) instead of the `PortForwarder` TCP proxy.

#### Scenario: Port mapping for a service
- **WHEN** a service with a host port (e.g., Postgres on 5432) is created via Docker
- **THEN** the container is created with `HostConfig.PortBindings` mapping the host port to the container port
- **THEN** the service is accessible on `localhost:<port>` without PortForwarder

#### Scenario: Service without a port
- **WHEN** a service without a host port (e.g., Worker) is created via Docker
- **THEN** no port bindings are configured but the container is still on the shared network

### Requirement: Docker volume mounts
The system SHALL use Docker bind mounts for persistent data instead of ext4 block device images.

#### Scenario: Postgres data volume
- **WHEN** the Postgres container is created via Docker
- **THEN** a bind mount maps `~/Library/Application Support/ErrandDesktop/data/postgres/` to `/var/lib/postgresql/data` inside the container

#### Scenario: Valkey data volume
- **WHEN** the Valkey container is created via Docker
- **THEN** a bind mount maps `~/Library/Application Support/ErrandDesktop/data/valkey/` to `/data` inside the container

### Requirement: Docker bridge network for inter-container communication
The system SHALL create a dedicated Docker bridge network for all Errand containers.

#### Scenario: Network creation on startup
- **WHEN** services start for the first time
- **THEN** the runtime creates a Docker network named `errand` (if it doesn't exist)
- **THEN** all containers are attached to this network

#### Scenario: Container DNS resolution
- **WHEN** the backend container needs to connect to Postgres
- **THEN** it can use the container name `errand-postgres` as the hostname

### Requirement: Docker exec for health checks and commands
The system SHALL use the Docker exec API for running commands inside containers.

#### Scenario: Health check exec
- **WHEN** a health check needs to run `pg_isready` in the Postgres container
- **THEN** the runtime calls `POST /containers/{id}/exec` to create an exec instance
- **THEN** it calls `POST /exec/{id}/start` and reads the output
- **THEN** it inspects the exec instance for the exit code

### Requirement: Docker image pulling with progress
The system SHALL pull Docker images with progress reporting.

#### Scenario: Pull image with progress
- **WHEN** an image needs to be pulled
- **THEN** the runtime calls `POST /images/create?fromImage=...`
- **THEN** it streams the JSON progress output and reports layer download progress

#### Scenario: Image already present
- **WHEN** an image is already present locally
- **THEN** the pull completes immediately and reports 100% progress
