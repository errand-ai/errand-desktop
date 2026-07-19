## Context

ErrandDesktop manages the errand stack as local containers. The errand backend v0.82.0 merged the worker process into the server via an async TaskManager — the separate `worker.py` entrypoint was deleted. The server now handles task processing directly, using the same container runtime interface (`CONTAINER_RUNTIME` env var) to create task-runner containers. ErrandDesktop's Bridge API remains the mechanism for task-runner creation on both Apple Containerization and Docker runtimes.

Additionally, Playwright MCP is now deployed as a standalone service (not a worker sidecar) with `--isolated` mode for concurrent session support.

## Goals / Non-Goals

**Goals:**

- Remove the worker container from ErrandDesktop's service management
- Configure the backend container with bridge env vars so the server's TaskManager creates task-runners via the Bridge API
- Deploy Playwright MCP as an always-on standalone container service
- Ensure both Apple Containerization and Docker runtimes work correctly

**Non-Goals:**

- Changing the Bridge API itself (it remains unchanged)
- Adding Playwright configuration UI (always-on, no toggle needed)
- Docker socket mounting (bridge handles container creation, not direct Docker access)

## Decisions

### 1. Remove worker entirely, don't stub it

**Choice:** Delete all worker references — service entry, dependency graph, env vars, command override, health check, image spec, rootfs/content sizes.

**Rationale:** The `worker.py` entrypoint no longer exists in the errand image. Keeping a stub would cause startup failures. Clean removal is the only option.

### 2. Backend gets bridge env vars

**Choice:** Move `CONTAINER_RUNTIME=apple`, `CONTAINER_BRIDGE_URL`, `CONTAINER_BRIDGE_TOKEN`, `TASK_RUNNER_IMAGE`, and `ERRAND_MCP_URL` to the backend env vars. Keep `ERRAND_CONTAINER_RUNTIME` for telemetry.

**Alternative considered:** Setting `CONTAINER_RUNTIME=docker` and mounting the Docker socket. Rejected because the Bridge API is the established pattern for errand-desktop on both runtimes, and avoids Docker socket complexity inside containers.

**Rationale:** The server's `create_runtime()` factory reads `CONTAINER_RUNTIME`. Setting it to `"apple"` triggers the `AppleContainerRuntime` which uses the Bridge API. This is the same mechanism the worker used previously.

### 3. Playwright as always-on service with no dependencies

**Choice:** Deploy Playwright with empty dependency array (starts in first wave alongside Postgres/Valkey). No config toggle — always deployed.

**Alternative considered:** Making Playwright optional with a toggle like Hindsight. Rejected because browser automation is core functionality and the server expects Playwright to be available.

**Rationale:** Playwright is stateless, starts fast, and has no external dependencies. The `--isolated` flag ensures concurrent task-runners get isolated browser contexts. Starting early means it's ready before any tasks execute.

### 4. Backend dependency chain unchanged

**Choice:** Backend still depends on `migrate`. Playwright has no dependents — the backend reads `PLAYWRIGHT_MCP_URL` and injects it into task-runners, but doesn't fail if Playwright isn't ready at backend startup.

**Rationale:** The TaskManager injects `PLAYWRIGHT_MCP_URL` into task-runner MCP configs at task execution time, not startup. If Playwright starts slightly after the backend, tasks that don't need browser tools work fine, and browser tasks wait until Playwright is healthy.

### 5. HINDSIGHT_URL and HINDSIGHT_BANK_ID on backend

**Choice:** Add `HINDSIGHT_URL` (pointing to Hindsight container) and `HINDSIGHT_BANK_ID=errand-tasks` to the backend env vars. Keep existing `HINDSIGHT_BASE_URL` as well.

**Rationale:** These serve different purposes: `HINDSIGHT_BASE_URL` is used by the server for its own API calls to Hindsight. `HINDSIGHT_URL` is injected by the TaskManager into task-runner container configs so task-runners can access Hindsight. Both are needed.

## Risks / Trade-offs

**[Playwright image size]** The `mcr.microsoft.com/playwright/mcp` image includes Chromium and is ~1.5GB. This increases first-run pull time. **Mitigation:** Pull happens asynchronously with progress UI. Image is cached after first pull.

**[Playwright memory usage]** Chromium consumes significant memory when active. **Mitigation:** With `--isolated` mode, browser contexts are created on-demand and cleaned up per session. Idle memory is moderate (~200MB). Users already opted into running a full local stack.

**[Breaking change for existing installs]** Users on older errand images will lose the worker container. **Mitigation:** The worker service simply won't appear. If the older image's worker.py is needed, users should not upgrade errand-desktop until they upgrade the errand image.
