## MODIFIED Requirements

### Requirement: Runtime auto-detection
The system SHALL detect available container runtimes on startup based on macOS version, CPU architecture, and installed software. The minimum macOS version on which the app itself launches is Sequoia (15); auto-detection runs on every supported host.

#### Scenario: macOS 26 + Apple Silicon with Docker installed
- **WHEN** the app starts on macOS 26 with Apple Silicon and Docker is installed
- **THEN** both Docker and Apple Containerization are reported as available
- **THEN** Docker is the default selection

#### Scenario: macOS 26 + Apple Silicon without Docker
- **WHEN** the app starts on macOS 26 with Apple Silicon but Docker is not installed
- **THEN** only Apple Containerization is reported as available
- **THEN** Apple Containerization is auto-selected

#### Scenario: Sequoia on Apple Silicon with Docker installed
- **WHEN** the app starts on macOS 15 (Sequoia) with Apple Silicon and Docker is installed
- **THEN** only Docker is reported as available (Apple Containerization is hidden because it requires macOS 26)
- **THEN** Docker is auto-selected

#### Scenario: Sequoia or later on Intel with Docker installed
- **WHEN** the app starts on macOS 15+ with Intel hardware and Docker is installed
- **THEN** only Docker is reported as available (Apple Containerization is hidden because it requires Apple Silicon)
- **THEN** Docker is auto-selected

#### Scenario: No runtime available
- **WHEN** the app starts and neither Docker nor Apple Containerization is available
- **THEN** the app displays an error with instructions to install Docker Desktop
