# Proposal: Cloud Storage MCP Services

## Problem

ErrandDesktop manages the full errand stack as local containers via Apple Containerization. The errand backend is gaining cloud storage integration (Google Drive, OneDrive) that requires two new MCP server containers to be deployed alongside the existing services. Users need the ability to enable/disable each cloud storage MCP server independently, and the necessary environment variables must be passed through to the backend and worker containers.

## Solution

Extend ErrandDesktop to optionally manage two new container services — `google-drive-mcp-server` and `one-drive-mcp-server` — following the established pattern used by LiteLLM and Hindsight (optional services with config toggles and dependency graph integration).

### AppConfig Extensions

Add two new toggles and port settings to `AppConfig`:

```swift
var useGoogleDrive: Bool = false
var googleDrivePort: Int = 8081

var useOneDrive: Bool = false
var oneDrivePort: Int = 8082
```

Defaults to `false` (disabled) since the services require the user to have set up OAuth credentials in the errand backend settings before they're useful.

### Service Lifecycle

New service entries in the dependency graph:

```swift
let serviceDependencies: [String: [String]] = [
    "postgres": [],
    "valkey": [],
    "migrate": ["postgres"],
    "litellm": ["postgres"],
    "hindsight": ["litellm"],
    "gdrive-mcp": [],        // no dependencies — stateless HTTP server
    "onedrive-mcp": [],      // no dependencies — stateless HTTP server
    "backend": ["migrate"],
    "worker": ["backend"],
]
```

The MCP servers have no dependencies — they're stateless HTTP services that start immediately alongside Postgres and Valkey. They only need to be healthy before the worker launches tasks (the worker checks URL env vars at task time, not startup).

Container images:
- `ghcr.io/devops-consultants/google-drive-mcp-server:{tag}`
- `ghcr.io/devops-consultants/one-drive-mcp-server:{tag}`

### Environment Variable Injection

When a cloud storage MCP server is enabled, inject its URL into the backend and worker containers:

- `useGoogleDrive: true` → inject `GDRIVE_MCP_URL=http://{gdrive-mcp-container-ip}:8080/mcp` into backend and worker env
- `useOneDrive: true` → inject `ONEDRIVE_MCP_URL=http://{onedrive-mcp-container-ip}:8080/mcp` into backend and worker env

This follows the same pattern as `HINDSIGHT_URL` — the backend uses the URL to determine if the integration settings page should be active, and the worker uses it to decide whether to inject the MCP server into task-runner configurations.

No port forwarding to localhost is needed for these services — they only need to be reachable from the backend/worker containers via the vmnet network. However, port forwarding could be added later for debugging.

### Settings UI

Add a new section to the Settings view, following the LiteLLM pattern:

- Toggle: "Google Drive MCP Server" (on/off)
- Toggle: "OneDrive MCP Server" (on/off)
- Brief description explaining that enabling the service allows agents to access cloud storage, and that OAuth credentials must be configured in the errand backend Settings > Integrations page

The toggles trigger service start/stop like the existing LiteLLM and Hindsight toggles.

### Health Checks

Simple HTTP health check for both services — `GET /health` or `GET /mcp` returning 200. Same pattern as the backend HTTP health check.

## Non-Goals

- OAuth credential management — handled by the errand backend, not the desktop app
- Cloud storage configuration UI — the errand backend's Settings > Integrations page handles this
- Building or bundling the MCP server code — images are pulled from GHCR like all other services
