## MODIFIED Requirements

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
