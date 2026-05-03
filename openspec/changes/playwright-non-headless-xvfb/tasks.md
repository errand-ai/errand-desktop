## 1. ContainerConfig and DockerRuntime

- [x] 1.1 Add `entrypoint: [String]?` field to `ContainerConfig` in `ContainerRuntime.swift`
- [x] 1.2 Add `shmSize: Int64?` field to `ContainerConfig` in `ContainerRuntime.swift` (default nil)
- [x] 1.3 Update `DockerRuntime.createContainer` to include `"Entrypoint"` in JSON body when `config.entrypoint` is set
- [x] 1.4 Update `DockerRuntime.createContainer` to include `"ShmSize"` in HostConfig when `config.shmSize` is set

## 2. ContainerEngine Playwright Command

- [x] 2.1 Update `commandOverride(for:)` in `ContainerEngine.swift`: for Docker runtime, return script as Cmd; for Apple runtime, return `["sh", "-c", "<xvfb + mcp server script>"]`
- [x] 2.2 Add `entrypointOverride(for:)` method: for Docker playwright, return `["sh", "-c"]`
- [x] 2.3 Add `shmSizeOverride(for:)` method: return 2GB for playwright

## 3. Testing

- [ ] 3.1 Build and run errand-desktop, verify Playwright container starts successfully with Xvfb
- [ ] 3.2 Verify Playwright MCP responds on port 3000 and task-runners can connect
