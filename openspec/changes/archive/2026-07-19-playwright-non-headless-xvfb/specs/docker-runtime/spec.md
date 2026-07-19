## ADDED Requirements

### Requirement: Docker entrypoint override

The Docker runtime SHALL support an optional `entrypoint` field in `ContainerConfig`. When set, `DockerRuntime.createContainer` SHALL include `"Entrypoint"` in the container create JSON body, overriding the image's default entrypoint.

#### Scenario: Entrypoint override provided

- **WHEN** a container is created with `config.entrypoint` set to `["sh", "-c", "some command"]`
- **THEN** the Docker API create request includes `"Entrypoint": ["sh", "-c", "some command"]` in the body

#### Scenario: No entrypoint override

- **WHEN** a container is created with `config.entrypoint` as nil
- **THEN** the Docker API create request does not include an `"Entrypoint"` field, using the image default

### Requirement: Docker shared memory size

The Docker runtime SHALL support an optional `shmSize` field in `ContainerConfig`. When set, `DockerRuntime.createContainer` SHALL include `"ShmSize"` in the `HostConfig` section of the container create JSON body.

#### Scenario: Shared memory size provided

- **WHEN** a container is created with `config.shmSize` set to `2147483648` (2GB)
- **THEN** the Docker API create request includes `"ShmSize": 2147483648` in `HostConfig`

#### Scenario: No shared memory override

- **WHEN** a container is created with `config.shmSize` as nil
- **THEN** the Docker API create request does not include `"ShmSize"`, using Docker's default (64MB)
