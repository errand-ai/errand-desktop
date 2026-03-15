## Context

ErrandDesktop manages the full errand stack as local containers via Apple Containerization. Optional services (LiteLLM, Hindsight) follow an established pattern: `AppConfig` boolean toggle, entry in `serviceDependencies`, container lifecycle management in `ContainerEngine`, env var injection into dependent services, and a toggle in `SettingsView`.

The errand backend is gaining cloud storage integration that requires two new MCP server containers to be optionally deployed. This change adds them as optional services following the existing pattern.

## Goals / Non-Goals

**Goals:**

- Add Google Drive and OneDrive MCP servers as optional container services
- Follow the established LiteLLM/Hindsight pattern for optional services
- Inject MCP server URLs as env vars into backend and worker containers
- Provide settings UI toggles for enabling/disabling each service
- Ensure clean startup/shutdown with no dependency complications

**Non-Goals:**

- OAuth credential management (handled by errand backend UI)
- Cloud storage configuration (handled by errand backend Settings > Integrations)
- Port forwarding to localhost (services only need to be reachable from backend/worker via vmnet)

## Decisions

### 1. Follow the LiteLLM/Hindsight optional service pattern

**Choice:** Add services using the same pattern as `useLiteLLM` and `useHindsight` — config toggles, dependency graph entries, container lifecycle in `ContainerEngine`, env injection, settings toggles.

**Rationale:** The pattern is proven, well-tested, and consistent. Users already understand the toggle behavior from LiteLLM/Hindsight.

### 2. No dependencies in the service graph

**Choice:** Both MCP server services have empty dependency arrays — they start immediately in the first wave alongside Postgres and Valkey.

**Rationale:** The MCP servers are stateless HTTP services with no database or other service dependencies. They just need to be running before tasks execute, which is guaranteed since tasks only run after the worker is healthy (worker depends on backend depends on migrate depends on postgres).

### 3. Defaults to disabled

**Choice:** `useGoogleDrive: false` and `useOneDrive: false` by default.

**Rationale:** Unlike LiteLLM (which is useful immediately with an API key), cloud storage MCP servers require the user to first set up OAuth credentials in the errand backend. Enabling by default would start containers that serve no purpose until configured.

### 4. Env var injection into backend and worker

**Choice:** When enabled, inject `GDRIVE_MCP_URL` / `ONEDRIVE_MCP_URL` as env vars into the backend and worker containers, pointing to the container's vmnet IP address.

**Rationale:** Same pattern as `HINDSIGHT_URL`. The backend uses the URL to determine if the integration settings page should be active. The worker uses it to decide whether to inject the MCP server into task-runner configurations.

### 5. HTTP health check

**Choice:** Health check via `GET /health` expecting HTTP 200, similar to the backend HTTP health check.

**Rationale:** The MCP servers are HTTP services. A simple HTTP probe confirms the server is running and accepting connections.

## Risks / Trade-offs

**[Image pull time]** Two additional container images to pull on first enable, which could be slow on poor connections. **Mitigation:** Images are small (Python + FastMCP + httpx). Pull happens asynchronously with progress UI (existing pattern). The `contentManagerImageTag` already controls image versioning.

**[Resource usage]** Each MCP server container uses some memory even when idle. **Mitigation:** FastMCP servers are lightweight (~50MB RSS). Disabled by default. Users only enable what they need.
