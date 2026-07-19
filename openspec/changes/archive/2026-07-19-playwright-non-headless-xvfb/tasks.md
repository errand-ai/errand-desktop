## 1. ContainerConfig and DockerRuntime

- [x] 1.1 Add `entrypoint: [String]?` field to `ContainerConfig` in `ContainerRuntime.swift`
- [x] 1.2 Add `shmSize: Int64?` field to `ContainerConfig` in `ContainerRuntime.swift` (default nil)
- [x] 1.3 Update `DockerRuntime.createContainer` to include `"Entrypoint"` in JSON body when `config.entrypoint` is set
- [x] 1.4 Update `DockerRuntime.createContainer` to include `"ShmSize"` in HostConfig when `config.shmSize` is set

## 2. ContainerEngine Playwright Command

- [x] 2.1 Update `commandOverride(for:)` in `ContainerEngine.swift`: for Docker runtime, return script as Cmd; for Apple runtime, return `["sh", "-c", "<xvfb + mcp server script>"]`
- [x] 2.2 Add `entrypointOverride(for:)` method: for Docker playwright, return `["sh", "-c"]`
- [x] 2.3 Add `shmSizeOverride(for:)` method: return 2GB for playwright
- [x] 2.4 Wire `entrypointOverride` and `shmSizeOverride` through `startSingleService` (the `startAll` path), not just `startService`, so Docker's full-stack startup actually applies them
- [x] 2.5 Scrub stale `/tmp/.X99-lock` and `/tmp/.X11-unix/X99` before starting Xvfb (Apple Containerization reuses rootfs across restarts, leaving lock files behind)
- [x] 2.6 Replace fixed `sleep 1` with a poll-for-socket loop with fail-fast

## 3. Service Dependency Graph

- [x] 3.1 Add `playwright` to `backend`'s dependency list in `ServiceInfo.swift` so backend is created only after Playwright is healthy
- [x] 3.2 Regression tests in `ServiceDependencyTests`: `testBackendDependsOnPlaywright`, `testPlaywrightHasNoDependencies`, `testPlaywrightShutdownAfterBackend`

## 4. Task-Runner Resource Fix (bundled)

The non-headless Playwright path makes task-runner sessions hold more state (MCP catalog, tool calls, browser context). The original 256 MiB / 1 CPU limit was already tight; with the new flow it consistently OOM-kills (exit 137).

- [x] 4.1 Bump task-runner `memoryInBytes` from 256 MiB to 8 GiB and `cpus` from 1 to 2 in `ContainerEngine.createTaskContainer`'s ContainerConfig. Raised in stages as multi-turn browser sessions kept hitting exit 137: 256 MiB → 2 GiB → 8 GiB (8 GiB clears 35B-class models with multi-turn browser tool use).

## 5. Testing

- [x] 5.1 `swift build` clean
- [x] 5.2 `swift test` 10/10 (including 3 new dependency-graph regression tests)
- [x] 5.3 `make run` on Apple runtime: Playwright container starts cleanly under Xvfb (no "already active for display 99"), `playwright healthy after 1 attempts`
- [x] 5.4 Playwright MCP reachable on port 3000; task-runners successfully `Connected to MCP server 'playwright' at http://192.168.64.x:3000/mcp`
- [x] 5.5 Manual end-to-end: submit a task that drives Playwright, verify it does not exit 137 and writes `/output/result.json`
