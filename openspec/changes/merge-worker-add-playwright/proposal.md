## Why

The errand backend v0.82.0 merged the worker's task processing into the server process (via an async TaskManager). The separate `worker.py` entrypoint no longer exists. ErrandDesktop still starts a dedicated worker container with `python worker.py`, which fails on v0.82.0+ images. Additionally, the errand server now expects a standalone Playwright MCP service for browser automation in tasks, deployed with `--isolated` mode for concurrent session safety. ErrandDesktop needs to reflect both changes.

## What Changes

- **BREAKING**: Remove the `worker` service container entirely — no more separate worker process, command override, env vars, or health check
- Move task-runner management env vars (`CONTAINER_RUNTIME`, `CONTAINER_BRIDGE_URL`, `CONTAINER_BRIDGE_TOKEN`, `TASK_RUNNER_IMAGE`, `ERRAND_MCP_URL`) from the worker to the backend container, so the server's TaskManager uses the Bridge API for container creation
- Add `HINDSIGHT_URL` and `HINDSIGHT_BANK_ID` to the backend env vars (previously only on worker, now needed by TaskManager for task-runner injection)
- Add a `playwright` service container (`mcr.microsoft.com/playwright/mcp:latest`) with `--isolated` flag for concurrent browser session support
- Add `PLAYWRIGHT_MCP_URL` env var to the backend pointing to the Playwright container
- Fix `ERRAND_CONTAINER_RUNTIME` — keep for telemetry only, add correct `CONTAINER_RUNTIME=apple` for the runtime factory

## Capabilities

### New Capabilities
- `playwright-service`: Standalone Playwright MCP container deployed as an always-on service with `--isolated` mode, health-checked and managed alongside other services

### Modified Capabilities
- `container-runtime-abstraction`: Backend env vars change — bridge env vars move from worker to backend; `CONTAINER_RUNTIME=apple` added for runtime factory; `ERRAND_CONTAINER_RUNTIME` kept for telemetry only
- `cloud-storage-desktop-services`: No env var changes needed (GDRIVE/ONEDRIVE URLs already on backend), but worker removal affects the service list and startup sequence

## Impact

- **AppState.swift** — Remove `worker` from services array
- **ServiceInfo.swift** — Remove `worker` from `serviceDependencies`; add `playwright` with no dependencies
- **ContainerEngine.swift** — Remove worker env vars, command override, image spec, health check, rootfs/content size entries; add playwright service config; move bridge env vars to backend case; add `PLAYWRIGHT_MCP_URL` to backend env
- **MenuBarPopover.swift / SetupAssistantView.swift** — Worker no longer appears in visible services; playwright appears as always-on
- **BridgeServer.swift** — No changes needed (bridge API unchanged)
