## Context

ErrandDesktop today ships only as a hand-installed signed+notarized DMG with a hard requirement of macOS 26 (Tahoe) on Apple Silicon. The upstream constraint that drove that floor is Apple's `Containerization` framework, which requires macOS 26 + arm64. However, ErrandDesktop also implements a `DockerRuntime` backend that talks to any Docker-compatible socket (Docker Desktop, Colima, OrbStack, Rancher Desktop). The Docker backend has no architectural reason to require Tahoe or Apple Silicon — it's just been forced along by the SwiftPM deployment target.

A quick audit confirmed the codebase isolates Apple Containerization cleanly:

- Only `AppleContainerRuntime.swift` imports `Containerization` / `ContainerizationOCI`.
- `StorageManager.swift` imports `ContainerizationEXT4` for `EXT4.Formatter`, used only by `ensureDataDisk(for:sizeInMB:)` (postgres + valkey ext4 images, only relevant on the Apple-Cont path).
- `ContainerEngine` references `AppleContainerRuntime` only via `as?` casts at six sites; it does not import the framework directly.
- No direct `Virtualization` / `VZ*` / `vmnet` symbols appear outside the upstream package.

A trial `swift build -c release --arch x86_64` against the current source tree succeeded end-to-end, confirming `swift-containerization` itself compiles for Intel.

The remaining hard constraint is upstream: `swift-containerization`'s own `Package.swift` declares `platforms: [.macOS("15")]`. SwiftPM minimums propagate transitively at link time, so importing the package — even guarded by `@available` — forces our minimum to macOS 15 (Sequoia). Sonoma (14) is therefore not reachable without forking or splitting the build.

## Goals / Non-Goals

**Goals:**

- Single command install on any supported Mac: `brew install --cask errand-desktop`.
- The command works regardless of CPU architecture — user does not need to know whether they are on Apple Silicon or Intel.
- Lowest practical macOS minimum: Sequoia (15), opening Intel Macs and pre-Tahoe Apple Silicon Macs to the Docker runtime path.
- A single universal binary / DMG per release — no per-architecture artifacts that the user must choose between.
- Brew is the canonical upgrade channel; `brew upgrade --cask errand-desktop` works for users who installed via Brew.
- The in-app update notification continues to work for users who installed manually, and steers all users toward Brew when relevant.
- Apple Containerization remains available with full functionality on macOS 26 + Apple Silicon.

**Non-Goals:**

- In-app self-updating (Sparkle, custom updater). The notification stays a flag/banner only.
- Submission to the official `homebrew-cask` tap. Own tap (`errand-ai/homebrew-errand`) is the v1 distribution.
- Pre-Sequoia (Sonoma 14, Ventura 13) support. Blocked by `swift-containerization` minimum.
- Per-runtime DMG variants (e.g. a "lite" Docker-only build that omits swift-containerization entirely). Single fat binary is simpler and the size cost is acceptable.
- Auto-detecting Brew installs to suppress the in-app banner. The banner stays universal; copy is updated to mention Brew.

## Decisions

### Decision 1: Lower SwiftPM deployment target to macOS 15 (Sequoia), not Sonoma

`Package.swift` will change from `.macOS(.v26)` to `.macOS(.v15)`. Sonoma (14) was the user's initial preference but is unreachable because `swift-containerization` declares `platforms: [.macOS("15")]` and SwiftPM minimums are link-time, not gateable with `@available`.

**Alternatives considered:**

- **Sonoma (14) via dependency fork**: Would require maintaining a fork of `swift-containerization` with a lowered minimum. Rejected — high maintenance cost for a one-version audience gain.
- **Conditional inclusion via SwiftPM traits or split products**: Possible with newer SwiftPM, but introduces a build matrix (Apple-Cont vs Docker-only), splitting the binary surface. Rejected for v1; revisit if Sonoma support becomes important.
- **Stay at macOS 26**: Defeats the purpose of universal binary + Brew distribution. Rejected.

### Decision 2: Apple Containerization gated by `@available(macOS 26, *)` at three layers

The codebase already concentrates Apple-Cont specifics into a small surface area. We will:

1. Annotate the entire `AppleContainerRuntime` type with `@available(macOS 26, *)`.
2. Move ext4 disk image creation out of `StorageManager` and into `AppleContainerRuntime` (or a `@available(macOS 26, *)`-annotated extension thereof) so `StorageManager` no longer imports `ContainerizationEXT4`. The function `ensureDataDisk(for:sizeInMB:)` is only ever called from the Apple-Cont path (verified — `ContainerEngine` only invokes it inside `if let appleRuntime = runtime as? AppleContainerRuntime` blocks).
3. Wrap each `as? AppleContainerRuntime` cast site in `ContainerEngine` with `if #available(macOS 26, *) { ... }` so the cast is statically valid on older OSes.

Rationale: keeps the `@available` plumbing in three known files, no scattered guards, and keeps `StorageManager` callable from any code path.

**Alternatives considered:**

- **`#if canImport(Containerization)`**: SwiftPM dependencies are unconditionally importable when present, so this guard would never short-circuit. Wrong tool for the job.
- **Leave ext4 disk creation in `StorageManager` and just gate the function**: Possible, but the file-level `import ContainerizationEXT4` still attempts to load on macOS 15. In practice the framework is weakly-linked and loads fine, but cleaner separation makes the boundary obvious to future readers.

### Decision 3: Universal binary built in CI via two-arch slice + `lipo`

The CI job will build two release slices (`--arch arm64` and `--arch x86_64`) and combine them into a single Mach-O binary using `lipo -create` before code-signing and notarization. Both `swift build --arch arm64 --arch x86_64` and the two-pass `lipo` approach are viable; the two-pass approach is preferred because it reuses the existing successful `--arch arm64` build path and isolates Intel-specific build failures to a discrete CI step.

The resulting `ErrandDesktop.app` ships one universal Mach-O binary. `Info.plist`'s `LSMinimumSystemVersion` will be set to `15.0`.

**Alternatives considered:**

- **Single-pass `swift build --arch arm64 --arch x86_64`**: Cleaner, but couples the two slices into one build and obscures per-arch failures. Could be adopted later as a refinement.
- **Per-arch DMGs**: Forces the user (or the cask) to know about architecture. Rejected — defeats the user-facing goal.

### Decision 4: Distribution via own tap (`errand-ai/homebrew-errand`), not homebrew-cask

A new public repo `errand-ai/homebrew-errand` will host `Casks/errand-desktop.rb`. Install command becomes:

```
brew tap errand-ai/errand
brew install --cask errand-desktop
```

**Alternatives considered:**

- **Submit to official `homebrew-cask`**: Eliminates the `brew tap` step. Rejected for v1 — homebrew-cask has notability/maturity expectations, a slower review cycle, and the project hasn't yet stabilised release cadence. Revisit once Brew install metrics show meaningful usage.
- **No tap, distribute DMG only**: Status quo. Rejected — the whole point of this change.

### Decision 5: Cask uses `depends_on macos: ">= :sequoia"` with no `arch` stanza

Because the binary is universal, the cask does not need an `arch arm:..., intel:...` selector. `depends_on macos:` is sufficient to gate installs on macOS 14 and below, where Brew will refuse the install with a clear error.

`livecheck` will track GitHub Releases (`https://github.com/errand-ai/errand-desktop/releases.atom`) so `brew upgrade --cask errand-desktop` works automatically on each tagged release.

### Decision 6: UpdateChecker remains a flag/banner only; copy updated, repo path fixed

`UpdateChecker.swift` is purely a polling notification system — no download, no relaunch logic. Two changes:

1. Fix `repoPath` from `"errand/errand-desktop"` to `"errand-ai/errand-desktop"`. Currently silently 404s, so no users have ever seen an update notification.
2. Change notification copy from *"Click to download"* to be install-path agnostic and mention Brew first: *"ErrandDesktop X.Y.Z is available. Run `brew upgrade --cask errand-desktop`, or visit the release page."* The `userInfo` URL on the notification still opens the GitHub release page when clicked, so the manual-install path is preserved.

We deliberately do NOT detect whether the running app was installed via Brew. Detection would be brittle (running from `/Applications` looks identical for both paths) and the dual-action copy is fine for both audiences.

### Decision 7: GitHub Release naming convention is a contract

The cask's `url` stanza will reference a stable release-asset path:

```
https://github.com/errand-ai/errand-desktop/releases/download/v#{version}/ErrandDesktop.dmg
```

The CI release pipeline must produce exactly this filename (no architecture suffix, no version suffix in the filename) for every release. This becomes a release-pipeline requirement codified in the new `release-pipeline` capability spec.

## Risks / Trade-offs

- **[Risk] `swift-containerization` may add macOS 26-only API in a future minor release** that is unconditionally referenced from a public symbol, which would cause `AppleContainerRuntime` to fail to compile on Sequoia even with `@available` annotations. → Mitigation: pin the dependency version in `Package.swift` and run CI on a Sequoia runner so any regression is caught at PR time, not at release time.
- **[Trade-off] Universal binary is ~2× the size of a single-arch binary.** Acceptable: the ErrandDesktop app binary is small relative to the container images it pulls. Disk cost on user machines is negligible.
- **[Risk] `lipo`-merged slices can have subtle linker-flag differences** if the two `swift build` invocations don't match exactly. → Mitigation: factor the build into a CI helper that runs both slices with identical environment and flags, only varying `--arch`.
- **[Risk] Intel Macs running Sequoia have a tiny user base relative to Apple Silicon.** → Mitigation: this is fine — they're a bonus audience, not the primary target. The change still pays off for pre-Tahoe Apple Silicon users, who are likely the bulk of the new audience.
- **[Trade-off] Own tap requires users to learn `brew tap` first.** Two commands instead of one. → Mitigation: README presents the tap+install as a single copy-pasteable block; once tapped, future installs and upgrades are one command.
- **[Risk] Brew upgrade and in-app banner could double-notify** users who have both running. → Acceptable: the banner is once per launch + once per 24h, the Brew notification is on `brew upgrade` invocation. They don't overlap meaningfully.
- **[Risk] Existing macOS 26 + Apple Silicon users may worry the change degrades them.** → Mitigation: their experience is unchanged. Apple Containerization is still offered, still preferred where appropriate, still has full functionality. The change is purely additive for them.
- **[Risk] CI runner availability for x86_64 builds.** Apple is phasing out Intel macOS runners. → Mitigation: build x86_64 slice via cross-compilation on an arm64 runner (`swift build --arch x86_64` works fine on arm64 hosts, as confirmed locally). No Intel runner needed.

## Migration Plan

1. Land Sequoia-target + `@available` gating in a single PR. CI builds and signs as today, but for the new minimum. No release cut yet.
2. Land universal-binary CI changes in a second PR. Manually verify on an Intel + Sequoia machine and an Apple Silicon + Sequoia machine that the resulting `.app` launches and Docker runtime is selectable. Verify Apple Silicon + Tahoe still offers both runtimes.
3. Cut a tagged release with the universal DMG.
4. Create the `errand-ai/homebrew-errand` repo, add `Casks/errand-desktop.rb` pointing at the new release. Manually `brew install --cask` from the tap on a fresh Mac to verify install/launch.
5. Update `errand-desktop/README.md` and `CLAUDE.md` with the new install/upgrade story. Land `UpdateChecker.swift` copy + repo path fixes in the same PR.
6. Announce.

**Rollback:** If a release is broken, the cask's `livecheck` will pick up the next tag — there's no rollback unique to Brew distribution. For a critical regression, retag the previous release as latest (or yank the bad tag and re-cut). The in-app banner will continue to show whatever GitHub Releases reports as latest.

## Open Questions

- **Where does the codesigning identity / notarization API key live for the new release pipeline?** Existing CI already does this; we just need to confirm the workflow secrets are available to the universal-build step.
- **Should the tap repo also publish a `.json` or stable redirect for the cask version**, so the cask can use `livecheck do url ...` cleanly without needing the GitHub Atom feed? Probably not for v1 — Atom feed works.
- **Does the `make run` workflow need updates** for the new minimum (it currently copies to `/var/tmp` for vmnet to work)? On Sequoia + Docker mode, `/var/tmp` placement is unnecessary; the Makefile may be simplified or left as-is for backward compat.
- **Should `make` gain a `make brew-test` target** that builds + signs + drops a local DMG into a fixture cask for end-to-end verification before tagging? Nice-to-have, not blocking.
