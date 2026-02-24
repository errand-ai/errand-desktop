## 1. ContainerRuntime Protocol & Types

- [ ] 1.1 Define `ContainerRuntime` protocol with pull, create, start, stop, remove, exec, containerIP, logs, and cleanup methods
- [ ] 1.2 Define `ContainerConfig` struct (image, env, ports, volumes, command, network) and `ExecResult` struct (exitCode, stdout, stderr)
- [ ] 1.3 Define `RuntimeCapability` enum (docker, appleContainerization) and `RuntimeDetector` that checks macOS version, CPU arch, and Docker socket availability

## 2. Docker Runtime Implementation

- [ ] 2.1 Implement `DockerHTTPClient` — HTTP-over-Unix-socket client using NWConnection to `/var/run/docker.sock` with JSON request/response handling
- [ ] 2.2 Implement `DockerRuntime.pullImage` — `POST /images/create` with streaming JSON progress parsing and progress callback
- [ ] 2.3 Implement `DockerRuntime.createContainer` and `startContainer` — `POST /containers/create` with env, port bindings, bind mounts, network, and command; then `POST /containers/{id}/start`
- [ ] 2.4 Implement `DockerRuntime.stopContainer` and `removeContainer` — `POST /containers/{id}/stop` and `DELETE /containers/{id}`
- [ ] 2.5 Implement `DockerRuntime.execInContainer` — `POST /containers/{id}/exec`, `POST /exec/{id}/start`, and `GET /exec/{id}/json` for exit code
- [ ] 2.6 Implement `DockerRuntime.containerIP` — inspect container for IP on the `errand` network
- [ ] 2.7 Implement `DockerRuntime.containerLogs` — `GET /containers/{id}/logs?follow=true` as AsyncStream
- [ ] 2.8 Implement Docker bridge network management — create `errand` network if not exists on startup, attach containers to it
- [ ] 2.9 Implement `DockerRuntime.cleanup` — remove containers prefixed with `errand-` and `task-`, optionally remove network

## 3. Apple Container Runtime Extraction

- [ ] 3.1 Extract existing Apple Containerization logic from `ContainerEngine` into `AppleContainerRuntime` implementing `ContainerRuntime` protocol
- [ ] 3.2 Move rootfs extraction, kernel download, ext4 disk image creation, and vmnet networking into `AppleContainerRuntime`
- [ ] 3.3 Keep preparing progress polling logic in `AppleContainerRuntime.pullImage` or `createContainer`

## 4. ContainerEngine Refactor

- [ ] 4.1 Refactor `ContainerEngine` to accept a `ContainerRuntime` instance and delegate all container operations through it
- [ ] 4.2 Update `startAll` / `startSingleService` / `startService` to use runtime-agnostic `ContainerConfig` instead of direct Apple Containerization calls
- [ ] 4.3 Update `stopAll` / `stopContainer` to delegate through the runtime
- [ ] 4.4 Conditionally skip `PortForwarder` setup when using Docker runtime (Docker handles port publishing natively)
- [ ] 4.5 Conditionally skip kernel download when using Docker runtime
- [ ] 4.6 Update bridge server task-runner container creation to use the active runtime

## 5. Runtime Selection & Config

- [ ] 5.1 Add `containerRuntime` field to `AppConfig` (default: "docker") with persistence in config.json
- [ ] 5.2 Implement `RuntimeDetector` — check macOS version (`ProcessInfo`), CPU arch (`uname`), Docker socket (`FileManager.fileExists`), and Docker ping
- [ ] 5.3 Update `AppState.initialize()` to run runtime detection and instantiate the correct `ContainerRuntime`
- [ ] 5.4 Add runtime selection UI in `SettingsView` — picker when multiple runtimes available, informational label when only one

## 6. Setup Wizard Integration

- [ ] 6.1 Add a runtime selection step to `SetupAssistantView` — show available runtimes with descriptions, pre-select Docker
- [ ] 6.2 Add Docker install check — if Docker not available, show download link and "Check Again" button
- [ ] 6.3 Update step count and navigation for the new runtime step

## 7. Volume & Data Path Updates

- [ ] 7.1 Update `StorageManager` to create Docker-compatible data directories (plain directories instead of ext4 disk images) when Docker runtime is selected
- [ ] 7.2 Ensure Postgres and Valkey bind mount paths are correct for Docker runtime

## 8. Testing & Validation

- [ ] 8.1 Manually test full service lifecycle (start all → health checks → port access → stop all) with Docker runtime
- [ ] 8.2 Manually test Apple Containerization runtime still works on macOS 26 + ARM
- [ ] 8.3 Test runtime switching in Settings (requires service restart)
- [ ] 8.4 Test setup wizard flow with Docker available and with Docker not available
