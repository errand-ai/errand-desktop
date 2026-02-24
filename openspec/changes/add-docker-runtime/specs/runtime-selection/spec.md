## ADDED Requirements

### Requirement: Runtime auto-detection
The system SHALL detect available container runtimes on startup based on macOS version, CPU architecture, and installed software.

#### Scenario: macOS 26 + Apple Silicon with Docker installed
- **WHEN** the app starts on macOS 26 with Apple Silicon and Docker is installed
- **THEN** both Docker and Apple Containerization are reported as available
- **THEN** Docker is the default selection

#### Scenario: macOS 26 + Apple Silicon without Docker
- **WHEN** the app starts on macOS 26 with Apple Silicon but Docker is not installed
- **THEN** only Apple Containerization is reported as available
- **THEN** Apple Containerization is auto-selected

#### Scenario: Older macOS or Intel with Docker installed
- **WHEN** the app starts on macOS < 26 or Intel hardware and Docker is installed
- **THEN** only Docker is reported as available
- **THEN** Docker is auto-selected

#### Scenario: No runtime available
- **WHEN** the app starts and neither Docker nor Apple Containerization is available
- **THEN** the app displays an error with instructions to install Docker Desktop

### Requirement: Runtime selection in settings
The system SHALL allow the user to choose their container runtime in Settings when multiple runtimes are available.

#### Scenario: Multiple runtimes available
- **WHEN** the user opens Settings and both runtimes are available
- **THEN** a "Container Runtime" picker is shown with Docker and Apple Containerization options
- **THEN** changing the selection requires restarting services

#### Scenario: Single runtime available
- **WHEN** the user opens Settings and only one runtime is available
- **THEN** the runtime is shown as informational text (no picker)

### Requirement: Runtime selection in setup wizard
The system SHALL include runtime selection in the first-run setup wizard.

#### Scenario: Setup wizard runtime step
- **WHEN** the user reaches the runtime selection step in the setup wizard
- **THEN** available runtimes are shown with descriptions of trade-offs
- **THEN** Docker is pre-selected as the recommended default

#### Scenario: Docker not installed during setup
- **WHEN** the user reaches the runtime step and Docker is not installed
- **THEN** a message explains that Docker Desktop is required for the best experience
- **THEN** a link to download Docker Desktop is provided
- **THEN** a "Check Again" button re-scans for Docker availability

### Requirement: Runtime preference persistence
The system SHALL persist the user's runtime choice in AppConfig.

#### Scenario: Save runtime preference
- **WHEN** the user selects a runtime
- **THEN** the choice is saved to `config.json` as `containerRuntime` ("docker" or "apple")

#### Scenario: Load runtime preference
- **WHEN** the app starts and a runtime preference exists in config
- **THEN** the previously selected runtime is used (if still available)
- **THEN** if the saved runtime is no longer available, fallback to the best available option
