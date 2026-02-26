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
