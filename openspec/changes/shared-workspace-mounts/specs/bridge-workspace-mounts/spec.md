## ADDED Requirements

### Requirement: Mounts field on container-create

The bridge `POST /containers` request SHALL accept an optional `mounts` array. Each entry SHALL contain `host_path` (absolute path on the macOS host) and `container_path` (absolute path in the container). Each accepted mount SHALL be attached to the created task container read-write, scoped to that container only. Requests without `mounts` SHALL create containers exactly as before this change.

#### Scenario: Container created with workspace mount

- **WHEN** the Worker posts a create payload with `mounts: [{"host_path": "<approved dir>/reports", "container_path": "/shared"}]`
- **THEN** the created task container sees the host directory's live contents read-write at `/shared`

#### Scenario: Payload without mounts

- **WHEN** the create payload has no `mounts` field
- **THEN** the container is created with only the standard workspace/output mounts, identical to pre-change behavior

### Requirement: Mount validation against the approved directory

The bridge SHALL validate every requested mount before creating any container: the `host_path`, after standardization and symlink resolution, MUST equal or be contained within the resolved approved shared workspace directory; `container_path` MUST be absolute and MUST NOT be one of the reserved container paths (`/workspace`, `/output`, `/app`). If no approved directory is configured, all mount requests SHALL be rejected. A validation failure SHALL return an error response and SHALL NOT create a container.

#### Scenario: Path outside approved directory rejected

- **WHEN** a create payload requests `host_path: "/Users/x/.ssh"` while the approved directory is `/Users/x/Google Drive/My Drive/Errand`
- **THEN** the bridge returns an error and no container is created

#### Scenario: Traversal and symlink escape rejected

- **WHEN** a requested `host_path` uses `..` segments or a symlink that resolves outside the approved directory
- **THEN** the bridge rejects the request after path resolution

#### Scenario: No approved directory configured

- **WHEN** `mounts` is present but the user has not configured a shared workspace directory
- **THEN** the bridge rejects the request with an error indicating the workspace is not configured

#### Scenario: Reserved container path rejected

- **WHEN** a mount requests `container_path: "/workspace"`
- **THEN** the bridge rejects the request
