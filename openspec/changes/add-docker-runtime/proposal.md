## Why

Apple's Containerization framework requires macOS 26+ and Apple Silicon, and its rootfs extraction step causes long startup delays (30-60s+ for larger images). Docker is the industry standard, runs on macOS 13+ (Intel and ARM), and eliminates rootfs extraction entirely. Making Docker the primary runtime broadens hardware support and dramatically improves startup UX.

## What Changes

- Add Docker Engine API integration as the primary container runtime
- Abstract container operations behind a `ContainerRuntime` protocol so both Docker and Apple Containerization can be used
- Auto-detect macOS version and architecture to determine available runtimes
- On macOS 26 + Apple Silicon: offer user choice between Docker and Apple Containerization
- On older macOS / Intel: Docker is the only option
- Remove `PortForwarder` when using Docker (Docker handles port mapping natively via `-p` flags)
- Remove kernel download step when using Docker (no Linux VM kernel needed)
- Eliminate rootfs extraction wait when using Docker (images run directly)
- Add Docker availability check and install guidance in setup wizard

## Capabilities

### New Capabilities
- `container-runtime-abstraction`: Protocol-based abstraction (`ContainerRuntime`) that unifies Docker and Apple Containerization behind a common interface for pull, create, start, stop, exec, and health check operations
- `docker-runtime`: Docker Engine API client (HTTP over Unix socket) implementing the `ContainerRuntime` protocol, with Docker Compose-style networking via bridge networks
- `runtime-selection`: Auto-detection of available runtimes based on macOS version and CPU architecture, with user-facing selection in Settings and setup wizard

### Modified Capabilities
- `container-commands`: Existing container command specs need updating to account for runtime-specific behavior differences (e.g., port mapping, volume mounts, networking)

## Impact

- **ContainerEngine.swift**: Refactored from direct Apple Containerization calls to delegate through `ContainerRuntime` protocol
- **AppState.swift**: Adds runtime selection state, passes chosen runtime to ContainerEngine
- **SettingsView.swift**: New runtime selection UI (when multiple runtimes available)
- **SetupAssistantView.swift**: Docker install check, runtime selection step
- **PortForwarder.swift**: Bypassed when using Docker runtime (Docker handles port publishing)
- **New files**: `ContainerRuntime.swift` (protocol), `DockerRuntime.swift` (Docker implementation), `AppleContainerRuntime.swift` (existing logic extracted), `RuntimeDetector.swift` (capability detection)
- **Dependencies**: Optional dependency on DockerSwift or thin custom HTTP client for Docker Engine API
- **AppConfig**: New `containerRuntime` setting persisted in config.json
