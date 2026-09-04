## 1. Lower deployment target and gate Apple Containerization

- [x] 1.1 Change `Package.swift` platform from `.macOS(.v26)` to `.macOS(.v15)`. Pin the `swift-containerization` dependency to its current version (`from: "0.26.0"` → exact `.exact("0.26.0")` or a tight upper bound) so future minor bumps cannot silently raise our floor.
- [x] 1.2 Annotate the entire `AppleContainerRuntime` type in `Sources/ErrandDesktop/Container/AppleContainerRuntime.swift` with `@available(macOS 26, *)`.
- [x] 1.3 Move `ensureDataDisk(for:sizeInMB:)` and the `import ContainerizationEXT4` out of `Sources/ErrandDesktop/Storage/StorageManager.swift` and into an `@available(macOS 26, *)` extension on `AppleContainerRuntime` (or a new `AppleStorageHelpers.swift`). Update `ContainerEngine.swift` call sites accordingly.
- [x] 1.4 In `Sources/ErrandDesktop/Container/ContainerEngine.swift`, wrap each of the six `as? AppleContainerRuntime` cast sites in `if #available(macOS 26, *) { ... }` blocks. Verify call sites by searching for `AppleContainerRuntime` references.
- [x] 1.5 Run `swift build -c release` on macOS Sequoia (15) to confirm the project compiles end-to-end with the lower target. Resolve any new `@available` warnings/errors from SwiftUI or system frameworks revealed by the lower target.
- [x] 1.6 Run `swift build -c release --arch x86_64` to confirm the cross-compiled Intel slice still builds.
- [x] 1.7 Run `swift test` to confirm the existing test suite passes against the new minimum.

## 2. Universal binary build pipeline

- [x] 2.1 Add a CI script (or inline workflow step) that builds the `arm64` and `x86_64` slices separately with identical environment and flags, then merges them via `lipo -create -output ErrandDesktop ErrandDesktop-arm64 ErrandDesktop-x86_64`. Verify the merged binary with `lipo -info`.
- [x] 2.2 Update `.github/workflows/build.yml` to run the universal build on a `macos-15` (or later Apple Silicon) runner. Confirm Xcode toolchain on the runner can target macOS 15.
- [x] 2.3 Update `Info.plist` to set `LSMinimumSystemVersion` to `15.0`. Verify the bundled `Info.plist` in the built `.app` reflects this.
- [x] 2.4 Update the codesign step to sign the universal binary in place, then sign the `.app` wrapper. Verify with `codesign -dvv ErrandDesktop.app`.
- [x] 2.5 Update the notarization step to submit the universal DMG. Verify with `spctl --assess --type install` and `spctl --assess --type execute` on the embedded app.
- [x] 2.6 Ensure the release artifact is named exactly `ErrandDesktop.dmg` (no architecture suffix, no version suffix) so the cask URL pattern resolves.
- [ ] 2.7 Manual smoke test: launch the universal DMG's `.app` from `/Applications` on (a) Apple Silicon + Tahoe, (b) Apple Silicon + Sequoia, (c) Intel + Sequoia. Confirm runtime selection presents the expected options on each.

## 3. UpdateChecker fixes

- [x] 3.1 Fix `repoPath` in `Sources/ErrandDesktop/App/UpdateChecker.swift` from `"errand/errand-desktop"` to `"errand-ai/errand-desktop"`.
- [x] 3.2 Update the notification body in `postUpdateNotification` to read along the lines of: *"ErrandDesktop X.Y.Z is available. Run `brew upgrade --cask errand-desktop` or visit the release page."* Keep the existing click action that opens the release page in the default browser.
- [x] 3.3 Add or update a unit test that asserts the GitHub Releases URL constructed by `checkForUpdate` targets `errand-ai/errand-desktop`.

## 4. Homebrew tap repository

- [x] 4.1 Create the public repository `errand-ai/homebrew-errand` on GitHub. Add a top-level `README.md` with the install/upgrade instructions.
- [x] 4.2 Create `Casks/errand-desktop.rb` with `version`, `sha256`, `url` (pointing at `https://github.com/errand-ai/errand-desktop/releases/download/v#{version}/ErrandDesktop.dmg`), `name`, `desc`, `homepage`, `depends_on macos: ">= :sequoia"`, `app "ErrandDesktop.app"`, and a `livecheck` block targeting GitHub Releases.
- [x] 4.3 Validate the cask locally with `brew style --fix Casks/errand-desktop.rb` and `brew audit --cask --new errand-desktop` (or equivalent) before pushing.
- [ ] 4.4 End-to-end install verification: on a Mac that has never installed ErrandDesktop, run `brew tap errand-ai/errand && brew install --cask errand-desktop`, confirm `/Applications/ErrandDesktop.app` is present, and launch the app.
- [ ] 4.5 End-to-end upgrade verification: tag a patch release, confirm `brew upgrade --cask errand-desktop` picks up the new version on a previously-installed machine.

## 5. Documentation

- [x] 5.1 Update `README.md` in the errand-desktop repo with a "Install" section showing the Brew tap+install commands and the manual DMG fallback. Document the supported macOS / hardware matrix (Sequoia+ for Docker mode, Tahoe + Apple Silicon for Apple Containerization mode).
- [x] 5.2 Update `README.md` with a "Upgrading" section explaining that Brew is the canonical upgrade channel.
- [x] 5.3 Update `CLAUDE.md` to reflect the new minimum macOS, dual-runtime hardware support (Apple Silicon + Intel), Brew as the upgrade channel, and the `ErrandDesktop.dmg` naming contract.
- [x] 5.4 Update the homebrew tap repo's `README.md` with usage notes, link back to errand-desktop, and a brief "Why this tap exists" paragraph.

## 6. Release and announcement

- [x] 6.1 Cut the first release that meets all the new requirements: universal binary, `LSMinimumSystemVersion 15.0`, `ErrandDesktop.dmg` naming, signed and notarized.
- [x] 6.2 Update the cask in `errand-ai/homebrew-errand` to point at this release's tag and SHA. Push the cask update.
- [ ] 6.3 Announce the new install path (in the project README, release notes, and any user-facing channels). Note that existing users will see the in-app banner directing them to `brew upgrade` after the next release.
