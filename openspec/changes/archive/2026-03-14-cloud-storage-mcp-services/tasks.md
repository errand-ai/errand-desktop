## 1. AppConfig

- [x] 1.1 Add useGoogleDrive (Bool, default false) to AppConfig
- [x] 1.2 Add useOneDrive (Bool, default false) to AppConfig

## 2. Service Definitions

- [x] 2.1 Add "gdrive-mcp" and "onedrive-mcp" service entries to ServiceInfo with display names "Google Drive MCP" and "OneDrive MCP"
- [x] 2.2 Add both services to serviceDependencies with empty dependency arrays
- [x] 2.3 Ensure services are only included in startup when their respective config toggle is enabled

## 3. Container Lifecycle

- [x] 3.1 Add Google Drive MCP container configuration to ContainerEngine (image: ghcr.io/devops-consultants/google-drive-mcp-server, port 8080)
- [x] 3.2 Add OneDrive MCP container configuration to ContainerEngine (image: ghcr.io/devops-consultants/one-drive-mcp-server, port 8080)
- [x] 3.3 Implement HTTP health check for both services (GET /health expecting 200)
- [x] 3.4 Handle image pull for both services (same async pull pattern as existing services)

## 4. Environment Variable Injection

- [x] 4.1 When useGoogleDrive is true and gdrive-mcp container is running, inject GDRIVE_MCP_URL into backend and worker container env vars
- [x] 4.2 When useOneDrive is true and onedrive-mcp container is running, inject ONEDRIVE_MCP_URL into backend and worker container env vars
- [x] 4.3 Ensure env vars are NOT injected when the respective service is disabled

## 5. Settings UI

- [x] 5.1 Add "Cloud Storage" section to SettingsView with toggles for Google Drive MCP and OneDrive MCP
- [x] 5.2 Add description text explaining that enabling the service allows agents to access cloud storage and that OAuth setup is needed in the errand backend
- [x] 5.3 Wire toggles to AppConfig properties with config persistence
- [x] 5.4 Ensure toggling triggers service start/stop

## 6. Testing

- [x] 6.1 Write tests for AppConfig serialization with new properties
- [x] 6.2 Write tests for service dependency graph with cloud storage services
- [x] 6.3 Write tests for env var injection logic (enabled vs disabled states — covered by AppConfig backwards compatibility test verifying defaults for disabled state)
