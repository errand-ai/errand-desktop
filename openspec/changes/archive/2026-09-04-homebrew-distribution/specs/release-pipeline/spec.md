## ADDED Requirements

### Requirement: Universal binary in release artifacts

Each release SHALL ship a universal Mach-O binary containing both `arm64` and `x86_64` slices in a single `ErrandDesktop.app`. The build pipeline SHALL produce both slices and combine them via `lipo -create` (or the equivalent multi-arch `swift build` flags) before code-signing.

#### Scenario: Inspect the released app binary
- **WHEN** the released `ErrandDesktop.app/Contents/MacOS/ErrandDesktop` is inspected with `lipo -info`
- **THEN** the output reports two architectures: `x86_64 arm64`

#### Scenario: Both slices are functional
- **WHEN** the released app is launched on Intel macOS Sequoia
- **THEN** the app launches without architecture-related errors and the Docker runtime is selectable

#### Scenario: Apple Silicon slice retains full functionality
- **WHEN** the released app is launched on Apple Silicon macOS Tahoe
- **THEN** the app launches and Apple Containerization is selectable alongside Docker

### Requirement: Single DMG per release

Each tagged GitHub Release SHALL publish exactly one DMG asset, named `ErrandDesktop.dmg`, containing the universal `.app`. The pipeline SHALL NOT publish per-architecture DMGs (no `-arm64` / `-x86_64` suffixes).

#### Scenario: Release assets list
- **WHEN** a release is tagged and published
- **THEN** the release's downloadable assets include exactly one `.dmg` file
- **AND** that file is named `ErrandDesktop.dmg`

#### Scenario: Cask URL stability
- **WHEN** the cask references `https://github.com/errand-ai/errand-desktop/releases/download/v#{version}/ErrandDesktop.dmg`
- **THEN** the URL resolves successfully for every published release of the corresponding version

### Requirement: Minimum system version declared in Info.plist

The bundled `Info.plist` SHALL declare `LSMinimumSystemVersion` of `15.0` so that macOS itself refuses to launch the app on Sonoma or earlier.

#### Scenario: Info.plist value
- **WHEN** the released `ErrandDesktop.app/Contents/Info.plist` is inspected
- **THEN** the `LSMinimumSystemVersion` key has the value `15.0`

#### Scenario: Launch on Sonoma
- **WHEN** the released app is copied to `/Applications` on macOS 14
- **AND** the user double-clicks it
- **THEN** macOS shows a system error stating the app requires a newer version of macOS, and the app does not launch

### Requirement: Code signed and notarized

The released DMG and the embedded `.app` SHALL be signed with the project's Developer ID certificate and notarized by Apple before publication.

#### Scenario: Notarization status of DMG
- **WHEN** the release DMG is checked with `spctl --assess --type install`
- **THEN** the assessment passes (the DMG is accepted by Gatekeeper)

#### Scenario: Notarization status of app
- **WHEN** the embedded `.app` is checked with `spctl --assess --type execute`
- **THEN** the assessment passes (the app is accepted by Gatekeeper)

#### Scenario: First-launch on a clean Mac
- **WHEN** a user installs the cask on a Mac that has never seen the app before
- **AND** launches it from `/Applications`
- **THEN** the app opens without prompting the user to override Gatekeeper

### Requirement: GitHub Release naming convention

Each release SHALL be tagged in the form `v<semver>` (e.g. `v1.2.3`), matching the version string embedded in `Info.plist`'s `CFBundleShortVersionString`. This convention is a contract consumed by the cask's `version`, `url`, and `livecheck` stanzas.

#### Scenario: Tag format
- **WHEN** a release is published
- **THEN** the git tag has the prefix `v` followed by a semver version (e.g. `v1.2.3`)

#### Scenario: Version consistency
- **WHEN** a release is published with tag `v1.2.3`
- **THEN** `ErrandDesktop.app/Contents/Info.plist` contains `CFBundleShortVersionString = 1.2.3`

### Requirement: x86_64 slice may be cross-compiled from arm64 hosts

The build pipeline SHALL be permitted to produce the `x86_64` slice on an Apple Silicon CI runner (cross-compilation), so that the project does not depend on Apple-provided Intel macOS runners.

#### Scenario: Cross-compiled x86_64 slice
- **WHEN** CI runs on a `macos-15-arm64` (or equivalent Apple Silicon) runner
- **THEN** `swift build -c release --arch x86_64` succeeds without an Intel host
- **AND** the resulting slice is functional when merged into the universal binary
