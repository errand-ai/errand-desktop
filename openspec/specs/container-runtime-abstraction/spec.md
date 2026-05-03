## ADDED Requirements

### Requirement: ContainerRuntime protocol
The system SHALL define a `ContainerRuntime` protocol that abstracts all container lifecycle operations, allowing multiple backend implementations (Docker, Apple Containerization).

#### Scenario: Protocol defines required operations
- **WHEN** a new container runtime is implemented
- **THEN** it MUST implement: `pullImage`, `createContainer`, `startContainer`, `stopContainer`, `removeContainer`, `execInContainer`, `containerIP`, `containerLogs`, and `cleanup`

#### Scenario: Runtime-agnostic service startup
- **WHEN** `ContainerEngine` starts a service
- **THEN** it delegates all container operations to the active `ContainerRuntime` implementation without runtime-specific branching

### Requirement: Image reference resolution
Each runtime SHALL resolve image references appropriate to its backend. Docker uses standard registry references; Apple Containerization uses its local image store.

#### Scenario: Docker image reference
- **WHEN** the Docker runtime resolves an image for service "postgres"
- **THEN** it returns a standard Docker image reference (e.g., `ghcr.io/errand-ai/errand:v1.0`)

#### Scenario: Apple Containerization image reference
- **WHEN** the Apple Containerization runtime resolves an image for service "postgres"
- **THEN** it returns a reference compatible with the local OCI image store

### Requirement: Health check abstraction
The runtime SHALL support health checking via exec-based commands and HTTP probes, regardless of backend implementation.

#### Scenario: Exec-based health check via Docker
- **WHEN** a health check runs `pg_isready` inside a Docker container
- **THEN** the runtime executes the command via Docker exec API and returns the exit code

#### Scenario: Exec-based health check via Apple Containerization
- **WHEN** a health check runs `pg_isready` inside an Apple container
- **THEN** the runtime executes the command via the container's exec mechanism and returns the exit code

### Requirement: Network connectivity between containers
The runtime SHALL ensure containers can communicate with each other by IP address, regardless of backend.

#### Scenario: Docker bridge network
- **WHEN** using the Docker runtime
- **THEN** all Errand containers are placed on a shared Docker bridge network and can reach each other by container name or IP

#### Scenario: Apple Containerization vmnet
- **WHEN** using the Apple Containerization runtime
- **THEN** containers communicate via vmnet-assigned IP addresses

### Requirement: Worker service removal

The system SHALL NOT manage a separate `worker` container service. Task processing is now handled by the backend server's internal TaskManager.

#### Scenario: Worker absent from service list
- **WHEN** the app starts
- **THEN** no `worker` service entry exists in the services array or dependency graph

#### Scenario: Worker image not pulled
- **WHEN** the app pulls container images
- **THEN** no separate image is pulled for a worker service

### Requirement: Backend bridge env vars for task-runner management

The backend container SHALL receive the Bridge API env vars so the server's TaskManager can create task-runner containers via the Bridge API on both Apple Containerization and Docker runtimes.

#### Scenario: Backend receives bridge env vars
- **WHEN** the backend container is started
- **THEN** the following env vars are set:
  - `CONTAINER_RUNTIME=apple`
  - `CONTAINER_BRIDGE_URL=http://{hostGatewayIP}:{bridgePort}`
  - `CONTAINER_BRIDGE_TOKEN={token}`
  - `TASK_RUNNER_IMAGE=ghcr.io/errand-ai/errand-task-runner:{tag}`
  - `ERRAND_MCP_URL=http://{backendHost}:{port}/mcp`

#### Scenario: Telemetry env var preserved
- **WHEN** the backend container is started
- **THEN** `ERRAND_CONTAINER_RUNTIME` is set to `apple-docker` (Docker runtime) or `apple-container` (Apple Containerization runtime) for telemetry purposes

### Requirement: Hindsight task-runner env vars on backend

The backend container SHALL receive `HINDSIGHT_URL` and `HINDSIGHT_BANK_ID` env vars so the TaskManager can inject them into task-runner container configurations.

#### Scenario: Hindsight enabled
- **WHEN** the backend starts with Hindsight enabled
- **THEN** `HINDSIGHT_URL=http://{hindsightHost}:8888/` and `HINDSIGHT_BANK_ID=errand-tasks` are set on the backend container
- **AND** the existing `HINDSIGHT_BASE_URL` env var is also set (used by the server for its own Hindsight API calls)

#### Scenario: Hindsight disabled
- **WHEN** the backend starts with Hindsight disabled
- **THEN** neither `HINDSIGHT_URL` nor `HINDSIGHT_BANK_ID` are set on the backend container
