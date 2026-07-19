## ADDED Requirements

### Requirement: Google Drive MCP server config toggle

`AppConfig` SHALL include a `useGoogleDrive` boolean property (default: `false`).

#### Scenario: Default configuration
- **WHEN** app launches with a fresh config
- **THEN** `useGoogleDrive` is `false`

#### Scenario: User enables Google Drive
- **WHEN** user enables the Google Drive toggle in settings
- **THEN** `useGoogleDrive` is set to `true` and persisted to config.json

### Requirement: OneDrive MCP server config toggle

`AppConfig` SHALL include a `useOneDrive` boolean property (default: `false`).

#### Scenario: Default configuration
- **WHEN** app launches with a fresh config
- **THEN** `useOneDrive` is `false`

#### Scenario: User enables OneDrive
- **WHEN** user enables the OneDrive toggle in settings
- **THEN** `useOneDrive` is set to `true` and persisted to config.json

### Requirement: Service lifecycle management

When enabled, each cloud storage MCP server SHALL be managed as a container service following the existing optional service pattern (LiteLLM, Hindsight).

The services SHALL have no dependencies in the service dependency graph and start in the first wave alongside Postgres and Valkey.

#### Scenario: Google Drive enabled at startup
- **WHEN** app starts with `useGoogleDrive: true`
- **THEN** the `gdrive-mcp` service is included in the startup sequence
- **AND** its container image is pulled (if not cached) and started
- **AND** health check confirms the service is ready

#### Scenario: Google Drive disabled at startup
- **WHEN** app starts with `useGoogleDrive: false`
- **THEN** the `gdrive-mcp` service is NOT started

#### Scenario: User toggles service on while running
- **WHEN** user enables a cloud storage service in settings and saves
- **THEN** the config is persisted
- **AND** the service starts on the next full startup (same pattern as LiteLLM/Hindsight toggles)

#### Scenario: User toggles service off while running
- **WHEN** user disables a cloud storage service in settings and saves
- **THEN** the config is persisted
- **AND** the service is excluded from the next full startup

### Requirement: Environment variable injection

When a cloud storage MCP server is enabled and running, its URL SHALL be injected as an environment variable into the backend container.

#### Scenario: Google Drive enabled
- **WHEN** `useGoogleDrive` is `true` and the `gdrive-mcp` container is running at IP `192.168.64.X`
- **THEN** `GDRIVE_MCP_URL=http://192.168.64.X:8080/mcp` is injected into the backend container env vars

#### Scenario: OneDrive enabled
- **WHEN** `useOneDrive` is `true` and the `onedrive-mcp` container is running at IP `192.168.64.Y`
- **THEN** `ONEDRIVE_MCP_URL=http://192.168.64.Y:8080/mcp` is injected into the backend container env vars

#### Scenario: Service disabled
- **WHEN** `useGoogleDrive` is `false`
- **THEN** `GDRIVE_MCP_URL` is NOT injected into backend env vars

### Requirement: Settings UI toggles

The Settings view SHALL include toggles for enabling/disabling each cloud storage MCP server, with descriptions explaining their purpose.

#### Scenario: Settings display
- **WHEN** user opens Settings
- **THEN** there are toggles for "Google Drive MCP Server" and "OneDrive MCP Server"
- **AND** each toggle has a description explaining that enabling allows agents to access cloud storage

#### Scenario: Toggle reflects service status
- **WHEN** `useGoogleDrive` is `true` and the service is running
- **THEN** the Google Drive toggle is ON and the service shows as running in the service list

### Requirement: Health check

The app SHALL health-check cloud storage MCP server containers via `GET /health` expecting HTTP 200.

#### Scenario: Healthy service
- **WHEN** the `gdrive-mcp` container is running and responds to `GET /health` with HTTP 200
- **THEN** the service status is `running`

#### Scenario: Unhealthy service
- **WHEN** the `gdrive-mcp` container does not respond to health checks within the timeout
- **THEN** the service status is `error`
