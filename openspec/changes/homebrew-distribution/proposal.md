## Why

ErrandDesktop is currently distributed only as a hand-installed signed+notarized DMG that requires macOS 26 (Tahoe) and Apple Silicon, even though the Docker runtime backend is hardware- and OS-agnostic in principle. This blocks Intel Mac users and pre-Tahoe Apple Silicon users from installing the app at all, and leaves macOS users without a single-command install path. Distributing via Homebrew (`brew install --cask errand-desktop`) plus a universal binary that lowers the minimum to macOS 15 (Sequoia) opens the app to the full audience that the Docker runtime already supports, with one canonical install and upgrade channel.

## What Changes

- Lower the SwiftPM deployment target from `.macOS(.v26)` to `.macOS(.v15)` (Sequoia). Sonoma (14) is not viable because the upstream `swift-containerization` package itself declares `.macOS("15")`.
- Gate all Apple Containerization code paths behind `@available(macOS 26, *)` and `if #available(macOS 26, *)`:
  - `AppleContainerRuntime` (whole type)
  - `StorageManager.ensureDataDisk` and the `ContainerizationEXT4` use it depends on (refactor permitting)
  - The six `as? AppleContainerRuntime` cast sites in `ContainerEngine`
- Build a universal (`arm64` + `x86_64`) binary in CI by either passing `--arch arm64 --arch x86_64` to `swift build`, or building each slice and joining with `lipo -create`.
- Update `.github/workflows/build.yml` to produce a single signed+notarized `ErrandDesktop.dmg` per release (no per-arch artifact split). Update `Info.plist`'s `LSMinimumSystemVersion` to `15.0`.
- Create a new public Homebrew tap repository `errand-ai/homebrew-errand` containing `Casks/errand-desktop.rb`. The cask uses `depends_on macos: ">= :sequoia"`, includes a `livecheck` stanza pointing at GitHub Releases, and downloads the single universal DMG.
- Update `UpdateChecker.swift`:
  - Fix `repoPath` from `"errand/errand-desktop"` to `"errand-ai/errand-desktop"` (currently silently 404s).
  - Change the in-app notification copy to be install-path agnostic, mentioning `brew upgrade --cask errand-desktop` alongside the GitHub releases page link.
- Document the install command (`brew tap errand-ai/errand && brew install --cask errand-desktop`) and the upgrade story (`brew upgrade --cask errand-desktop`) in the project README. Brew is the supported upgrade channel; the app does not self-update.

## Capabilities

### New Capabilities

- `homebrew-distribution`: Defines the Homebrew tap and cask contract — naming, source DMG URL convention, supported macOS floor, architecture support claim, livecheck behaviour, and the relationship between GitHub Releases and `brew upgrade`.
- `release-pipeline`: Defines the CI build/sign/notarize/release contract — universal binary requirement, single-DMG-per-release rule, `Info.plist` minimum version, GitHub Release naming convention that the cask depends on.

### Modified Capabilities

- `runtime-selection`: The minimum supported OS shifts from macOS 26 to macOS 15. The behaviour rule "Apple Containerization is only offered on macOS 26+ Apple Silicon" is unchanged in spirit but must now be enforced on systems where the app itself is allowed to run (previously a no-op since the app couldn't launch at all on those systems).
- `container-runtime-abstraction`: Implementation must compile and run on macOS 15+, with Apple Containerization symbols guarded by `@available(macOS 26, *)`. The protocol surface is unchanged; the requirement that adds is "the abstraction must remain usable when the Apple Containerization implementation is unavailable at runtime."

## Impact

- **Source code**: `Package.swift`, `Sources/ErrandDesktop/Container/AppleContainerRuntime.swift`, `Sources/ErrandDesktop/Container/ContainerEngine.swift`, `Sources/ErrandDesktop/Storage/StorageManager.swift`, `Sources/ErrandDesktop/App/UpdateChecker.swift`.
- **Build & release**: `.github/workflows/build.yml`, `ErrandDesktop.entitlements` (no change expected, just verification), `Info.plist` (`LSMinimumSystemVersion`), `Makefile` (verify `make run` still works on Sequoia).
- **External**: New repository `errand-ai/homebrew-errand` containing `Casks/errand-desktop.rb` and a README. GitHub Releases naming convention becomes a contract that the cask consumes.
- **Documentation**: Project `README.md` updated with Homebrew install/upgrade instructions and the revised macOS support matrix. `CLAUDE.md` updated to reflect the new minimum macOS, dual-runtime hardware support, and Brew as the upgrade channel.
- **Users**: Existing users who installed via DMG will continue to work; on next launch, the in-app update notification will steer them toward `brew upgrade --cask errand-desktop`. Intel + Sequoia users gain the ability to install the app for the first time, in Docker-runtime-only mode.
- **Out of scope**: In-app self-update / Sparkle integration; submission to the official `homebrew-cask` tap (own tap only for v1); pre-Sequoia (Sonoma 14 or earlier) support.
