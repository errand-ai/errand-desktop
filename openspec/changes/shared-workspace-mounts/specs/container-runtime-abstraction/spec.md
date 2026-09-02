## ADDED Requirements

### Requirement: Task-container creation accepts mounts

`ContainerEngine.createTaskContainer` SHALL accept an optional list of validated mounts (host path → container path) in addition to image, env, and files, and SHALL pass them to the active `ContainerRuntime` implementation alongside the existing scratch workspace/output mounts. On Apple Containerization the mounts SHALL be attached as virtiofs shares (`Mount.share`); the mount mechanism SHALL be the same one already used for service-container directory shares. When no mounts are supplied, task-container creation SHALL be unchanged.

#### Scenario: Apple runtime attaches virtiofs share

- **WHEN** `createTaskContainer` is called with a mount for `/shared` while the Apple Containerization runtime is active
- **THEN** the task container's configuration includes a virtiofs share mapping the host path to `/shared`, alongside the standard workspace and output mounts

#### Scenario: No mounts supplied

- **WHEN** `createTaskContainer` is called without mounts
- **THEN** the container is created with only the standard scratch mounts, byte-identical to pre-change behavior
