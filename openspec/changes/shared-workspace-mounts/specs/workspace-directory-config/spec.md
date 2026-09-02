## ADDED Requirements

### Requirement: Shared workspace directory setting

`AppConfig` SHALL gain an optional `sharedWorkspacePath` persisted in `config.json`. The settings UI SHALL provide a Shared Workspace section with a folder picker (NSOpenPanel) to choose the directory, display of the currently configured path, and a control to clear it. The setting SHALL default to unset.

#### Scenario: Folder selected and persisted

- **WHEN** the user picks `~/Google Drive/My Drive/Errand` in the folder picker
- **THEN** the path is stored in `config.json` and shown in settings after app restart

#### Scenario: Setting cleared

- **WHEN** the user clears the shared workspace setting
- **THEN** `sharedWorkspacePath` is unset and subsequent bridge mount requests are rejected

### Requirement: Approved directory advertised to the Worker

When starting the Worker service container with `sharedWorkspacePath` configured, the app SHALL inject `SHARED_WORKSPACE_HOST_DIR=<path>` into the Worker's environment. When unset, the variable SHALL be omitted. The settings UI SHALL indicate that changing the path requires a Worker restart to take effect on the server side.

#### Scenario: Env var injected

- **WHEN** the Worker starts while a shared workspace directory is configured
- **THEN** the Worker environment contains `SHARED_WORKSPACE_HOST_DIR` with the configured path

#### Scenario: Env var omitted when unset

- **WHEN** the Worker starts with no shared workspace configured
- **THEN** `SHARED_WORKSPACE_HOST_DIR` is not present in the Worker environment

### Requirement: Mirrored-files guidance

The Shared Workspace settings section SHALL display guidance that the chosen folder must be locally materialized — "Mirror files" mode for Google Drive, "Always keep on this device" for OneDrive — because File Provider dataless placeholders are not reliably readable through container file sharing.

#### Scenario: Guidance visible

- **WHEN** the user views the Shared Workspace settings section
- **THEN** the mirrored-files requirement is stated alongside the folder picker
