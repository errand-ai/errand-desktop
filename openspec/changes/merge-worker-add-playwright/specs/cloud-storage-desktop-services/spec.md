## MODIFIED Requirements

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
