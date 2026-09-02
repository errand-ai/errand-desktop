## ADDED Requirements

### Requirement: Task-container bind mounts for workspace mounts

When the Docker runtime is active, workspace mounts passed to task-container creation SHALL be attached as read-write bind mounts (`Binds`), using the same mechanism as existing service-container volume mounts. Docker file-sharing scope caveats (e.g. Colima sharing only `$HOME` by default) SHALL be documented for the shared workspace directory.

#### Scenario: Docker task container gets bind mount

- **WHEN** a task container is created via the Docker runtime with a mount for `/shared`
- **THEN** the container is created with a read-write bind of the host path at `/shared` and file changes are visible bidirectionally

#### Scenario: No mounts on Docker

- **WHEN** a task container is created via the Docker runtime without workspace mounts
- **THEN** only the standard scratch workspace/output binds are present, unchanged from current behavior
