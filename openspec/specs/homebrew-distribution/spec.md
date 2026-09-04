## Purpose
Defines the Homebrew tap and cask contract: naming, the source DMG URL convention, the supported macOS floor, the architecture-support claim, tap trust, livecheck behaviour, and the relationship between GitHub Releases and `brew upgrade`.

## Requirements

### Requirement: Homebrew tap repository

The project SHALL maintain a public Homebrew tap repository at `errand-ai/homebrew-errand` that hosts the cask definition for ErrandDesktop.

#### Scenario: Tap is publicly reachable
- **WHEN** a user runs `brew tap errand-ai/errand`
- **THEN** Homebrew clones `https://github.com/errand-ai/homebrew-errand` successfully and registers the tap

#### Scenario: Tap contains the errand-desktop cask
- **WHEN** the tap is registered
- **THEN** the file `Casks/errand-desktop.rb` exists in the tap repository
- **AND** `brew search errand-desktop` lists it
- **AND** loading the cask still requires the tap to be trusted on Homebrew 6+

### Requirement: Tap trust is a documented prerequisite

Homebrew 6 refuses to load casks from non-official taps until the tap is trusted: `HOMEBREW_REQUIRE_TAP_TRUST` is the default, and `brew tap` does not prompt for trust. The documented install sequence SHALL therefore include `brew trust errand-ai/errand` between tapping and installing, annotated as applying to Homebrew 6 and later only — on Homebrew 5 and earlier the command does not exist and is not needed.

#### Scenario: Untrusted tap on Homebrew 6
- **WHEN** a user on Homebrew 6 or later registers the tap and runs `brew install --cask errand-desktop` without having trusted the tap
- **THEN** Homebrew refuses with an untrusted-tap error that names `brew trust errand-ai/errand`
- **AND** no files are written to `/Applications`

#### Scenario: Tap trusted on Homebrew 6
- **WHEN** the user runs `brew trust errand-ai/errand` and then `brew install --cask errand-desktop`
- **THEN** the install proceeds normally

#### Scenario: Documented install sequence
- **WHEN** a user follows the Install section of either the project README or the tap README
- **THEN** the documented sequence is `brew tap errand-ai/errand`, then `brew trust errand-ai/errand`, then `brew install --cask errand-desktop`
- **AND** the `brew trust` step is annotated as Homebrew 6+ only

### Requirement: Architecture-agnostic install

Once the tap is registered and trusted, the system SHALL install on any supported Mac via a single `brew install --cask errand-desktop`, without the user needing to know their CPU architecture or supply architecture-specific arguments.

#### Scenario: Install on Apple Silicon
- **WHEN** a user on Apple Silicon runs `brew install --cask errand-desktop` against a registered and trusted tap
- **THEN** Homebrew downloads the universal DMG, mounts it, and installs `ErrandDesktop.app` into `/Applications`
- **AND** no `--arch` or similar flag is required from the user

#### Scenario: Install on Intel
- **WHEN** a user on Intel macOS Sequoia or later runs `brew install --cask errand-desktop` against a registered and trusted tap
- **THEN** Homebrew downloads the same universal DMG and installs `ErrandDesktop.app` into `/Applications`
- **AND** no `--arch` or similar flag is required from the user

### Requirement: Minimum macOS gate enforced by cask

The cask SHALL refuse to install on unsupported macOS versions via a `depends_on macos:` declaration so that the user sees a clear refusal rather than a silent install of an unsupported binary.

#### Scenario: Install on macOS Sonoma (14)
- **WHEN** a user on macOS 14 runs `brew install --cask errand-desktop`
- **THEN** Homebrew refuses the install with a message indicating macOS Sequoia or later is required
- **AND** no files are written to `/Applications`

#### Scenario: Install on macOS Sequoia (15)
- **WHEN** a user on macOS 15 runs `brew install --cask errand-desktop`
- **THEN** the install proceeds normally

### Requirement: Brew is the supported upgrade channel

The cask SHALL be configured so that `brew upgrade --cask errand-desktop` retrieves new versions automatically when GitHub Releases publishes a new tag.

#### Scenario: New version available
- **WHEN** a new version is published to GitHub Releases for `errand-ai/errand-desktop`
- **AND** the user runs `brew upgrade --cask errand-desktop`
- **THEN** Homebrew detects the new version via livecheck and replaces the installed app with the new release

#### Scenario: Already up to date
- **WHEN** the user runs `brew upgrade --cask errand-desktop` and the installed version matches the latest GitHub Release
- **THEN** Homebrew reports the cask is already up to date

### Requirement: In-app update notification mentions Brew

The in-app update notification posted by `UpdateChecker` SHALL be install-path agnostic and mention `brew upgrade --cask errand-desktop` as a primary upgrade option, while still preserving the option to download from GitHub Releases.

#### Scenario: New version detected by UpdateChecker
- **WHEN** `UpdateChecker` finds that GitHub Releases reports a newer version than the running app
- **THEN** the macOS notification body mentions both `brew upgrade --cask errand-desktop` and the GitHub release page
- **AND** clicking the notification still opens the GitHub release page in the default browser

#### Scenario: UpdateChecker queries the correct repository
- **WHEN** `UpdateChecker` polls GitHub Releases
- **THEN** it queries `https://api.github.com/repos/errand-ai/errand-desktop/releases/latest` (not `errand/errand-desktop`)

### Requirement: Apple Containerization remains available where supported

Distributing via Homebrew SHALL NOT remove or degrade the Apple Containerization runtime on systems that support it (macOS 26 + Apple Silicon).

#### Scenario: Tahoe + Apple Silicon after Brew install
- **WHEN** a user on macOS 26 + Apple Silicon installs the cask and launches the app
- **THEN** both Docker and Apple Containerization runtimes are offered in the runtime selector
- **AND** Apple Containerization functions identically to the pre-Brew DMG install
