## Context

ErrandDesktop currently uses Apple's Containerization framework exclusively for running containers. This framework requires macOS 26+ and Apple Silicon, and involves a slow rootfs extraction step (30-60s+ for larger images like LiteLLM and Hindsight). Docker is the industry standard, runs on macOS 13+ on both Intel and ARM, and eliminates rootfs extraction entirely since images run directly.

The current `ContainerEngine` actor directly calls Apple Containerization APIs (`ContainerManager`, `ImageStore`, `LinuxContainer`). It also relies on `PortForwarder` (TCP proxy) because vmnet doesn't automatically expose container ports, and downloads a Kata Containers kernel on first run.

## Goals / Non-Goals

**Goals:**
- Docker as the primary and recommended container runtime
- Apple Containerization as an optional runtime on macOS 26 + Apple Silicon
- Auto-detection of available runtimes with user choice when both available
- Eliminate rootfs extraction, PortForwarder, and kernel download when using Docker
- Maintain all existing service lifecycle behavior (dependency ordering, health checks, ephemeral containers)

**Non-Goals:**
- Supporting Podman or other container runtimes (future consideration)
- Running without any container runtime (always needs at least one)
- Changing the BridgeServer or task-runner container architecture
- Docker Compose integration (we manage containers individually)

## Decisions

### 1. ContainerRuntime protocol as the abstraction layer

**Decision**: Define a Swift protocol `ContainerRuntime` that both Docker and Apple Containerization implement.

**Rationale**: A protocol gives compile-time safety, is idiomatic Swift, and keeps `ContainerEngine` runtime-agnostic. The alternative (enum-based switching with inline if/else) would scatter runtime-specific logic throughout `ContainerEngine`.

**Protocol shape:**
```swift
protocol ContainerRuntime: Sendable {
    func pullImage(reference: String, onProgress: (@Sendable (Double) -> Void)?) async throws
    func createContainer(id: String, config: ContainerConfig) async throws
    func startContainer(id: String) async throws
    func stopContainer(id: String, timeout: Int) async throws
    func removeContainer(id: String) async throws
    func execInContainer(id: String, command: [String]) async throws -> ExecResult
    func containerIP(id: String) async throws -> String?
    func containerLogs(id: String) async throws -> AsyncStream<String>
    func cleanup() async throws
}
```

`ContainerConfig` is a runtime-agnostic struct holding image, env vars, port mappings, volume mounts, command override, and network name.

### 2. Docker Engine API via thin custom HTTP client

**Decision**: Build a thin HTTP-over-Unix-socket client rather than depending on DockerSwift.

**Rationale**: DockerSwift has incomplete exec support and adds a large dependency. The Docker Engine API surface we need is small (~10 endpoints). Swift's `URLSession` supports Unix domain sockets via `NSURL` with `unix://` scheme, or we can use `NWConnection` (already in use for PortForwarder). This keeps the dependency footprint minimal.

**Alternatives considered:**
- DockerSwift library: Active but exec support is partial, large dependency
- Full Docker API client: Over-engineered for our needs

### 3. Docker bridge network for inter-container communication

**Decision**: Create a dedicated `errand` Docker bridge network and attach all containers to it.

**Rationale**: A bridge network gives containers DNS resolution by container name (e.g., `errand-postgres`) and IP-based communication, matching what vmnet provides for Apple Containerization. The default Docker bridge network doesn't provide DNS resolution.

### 4. Docker bind mounts instead of ext4 block devices

**Decision**: Use Docker bind mounts for Postgres and Valkey data persistence, pointing to the same `~/Library/Application Support/ErrandDesktop/data/` directory tree.

**Rationale**: Docker handles filesystem permissions internally. The ext4 block device approach is specific to Apple Containerization's VM model. Bind mounts are the standard Docker approach and require no special setup.

### 5. PortForwarder bypass for Docker

**Decision**: Skip `PortForwarder` entirely when using Docker. Docker's `-p` port publishing natively binds container ports to localhost.

**Rationale**: PortForwarder exists solely because Apple Containerization's vmnet doesn't expose container ports to the host. Docker handles this natively. The PortForwarder code remains for Apple Containerization but is not instantiated for Docker.

### 6. RuntimeDetector for capability detection

**Decision**: A `RuntimeDetector` utility checks macOS version, CPU architecture, and Docker socket availability to determine which runtimes are usable.

**Detection logic:**
- Apple Containerization: `ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26` AND `uname -m` returns `arm64`
- Docker: `FileManager.default.fileExists(atPath: "/var/run/docker.sock")` AND successful `GET /_ping`

### 7. Refactor ContainerEngine to delegate through runtime

**Decision**: `ContainerEngine` keeps its role as the orchestrator (dependency ordering, health checks, status updates) but delegates all container operations to the active `ContainerRuntime` instance.

**Rationale**: This is the least disruptive refactor. `ContainerEngine` already has the right abstraction level — it manages service lifecycle, not container details. Extracting the Apple Containerization specifics into `AppleContainerRuntime` and adding `DockerRuntime` keeps the diff contained.

## Risks / Trade-offs

- **Docker Desktop requirement**: Users must install Docker Desktop (or Colima/OrbStack). This is a third-party dependency we don't control. → Mitigation: Clear install guidance in setup wizard, link to download page.

- **Docker Desktop licensing**: Docker Desktop requires a paid subscription for companies > 250 employees or $10M revenue. → Mitigation: Document this; OrbStack and Colima are alternatives. Consider future Podman support.

- **Two code paths to maintain**: Having both runtimes means testing both. → Mitigation: The protocol abstraction keeps runtime-specific code isolated. Integration tests can run against whichever runtime is available.

- **Unix socket security**: Accessing `/var/run/docker.sock` gives full Docker daemon control. → Mitigation: This is standard for Docker client apps. No different from running `docker` CLI.

- **Data migration between runtimes**: Switching from Apple Containerization (ext4 images) to Docker (bind mounts) may not preserve existing data. → Mitigation: Document that switching runtimes resets container data. Postgres data can be exported/imported if needed.

- **URLSession Unix socket support**: Swift's URLSession may not natively support Unix domain sockets well. → Mitigation: Fall back to `NWConnection` with raw HTTP if needed, or use `curl` process as last resort.
