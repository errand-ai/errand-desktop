## 1. Remove Worker Service

- [x] 1.1 Remove `ServiceInfo(id: "worker", ...)` from the services array in AppState
- [x] 1.2 Remove `"worker"` from `serviceDependencies` in ServiceInfo.swift
- [x] 1.3 Remove `case "worker"` from `buildEnv` in ContainerEngine
- [x] 1.4 Remove `case "worker"` from `commandOverride` in ContainerEngine
- [x] 1.5 Remove `case "worker"` from `rootfsSize`, `estimatedContentSize`, and `checkHealth` in ContainerEngine
- [x] 1.6 Remove `"worker"` from `imageSpecs` in ContainerEngine (it shared the errand image with backend/migrate)
- [x] 1.7 Update backend `serviceDependencies` — backend currently depends on `migrate`, worker depended on `backend`; with worker gone, no change needed to backend deps

## 2. Move Bridge Env Vars to Backend

- [x] 2.1 Add `CONTAINER_RUNTIME=apple` to backend env vars (both runtimes use bridge)
- [x] 2.2 Add `CONTAINER_BRIDGE_URL` and `CONTAINER_BRIDGE_TOKEN` to backend env vars
- [x] 2.3 Add `TASK_RUNNER_IMAGE` to backend env vars
- [x] 2.4 Add `ERRAND_MCP_URL` (self-referencing) to backend env vars
- [x] 2.5 Keep `ERRAND_CONTAINER_RUNTIME` on backend for telemetry (already present)
- [x] 2.6 Add `HINDSIGHT_URL` and `HINDSIGHT_BANK_ID` to backend env vars (when Hindsight enabled)

## 3. Add Playwright Service

- [x] 3.1 Add `ServiceInfo(id: "playwright", displayName: "Playwright")` to services array in AppState
- [x] 3.2 Add `"playwright": []` to `serviceDependencies` (no dependencies)
- [x] 3.3 Add `playwright` image spec: `mcr.microsoft.com/playwright/mcp:latest`
- [x] 3.4 Add command override for playwright: `["--isolated", "--port", "3000", "--host", "0.0.0.0", "--allowed-hosts", "*"]`
- [x] 3.5 Add HTTP health check for playwright on port 3000
- [x] 3.6 Add rootfs and estimated content sizes for playwright
- [x] 3.7 Add `PLAYWRIGHT_MCP_URL` env var to backend pointing to `http://{playwrightHost}:3000/mcp`

## 4. Version Compatibility

- [x] 4.1 Filter GHCRTagFetcher results for the errand image to only show versions >= 0.82.0 (this is a breaking change — older images have a separate worker entrypoint that no longer exists)

## 5. Cleanup

- [x] 5.1 Remove worker from `visibleServices` filter in MenuBarPopover (no filter needed — worker entry is gone)
- [x] 5.2 Remove worker from `visibleServices` filter in SetupAssistantView (no filter needed — worker entry is gone)
- [x] 5.3 Verify build succeeds and tests pass
