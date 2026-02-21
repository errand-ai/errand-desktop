# ErrandDesktop — Task Completion Checklist

When completing a task or change in this project, follow these steps:

## Before Committing
1. **Build succeeds**: `swift build` completes without errors
2. **Tests pass**: `swift test` passes (once tests exist)
3. **Concurrency safety**: All types are `Sendable`, actors/MainActor used correctly
4. **No warnings**: Address any Swift compiler warnings

## Code Quality
- Consistent with existing patterns (see `style_and_conventions` memory)
- `@MainActor` for UI-facing state, `actor` for background managers
- Doc comments on public API
- `// MARK: -` sections in large files
- Error types conform to `LocalizedError`

## Integration Points
- If modifying `ContainerEngine`: check that `BridgeServer` routes still work correctly
- If modifying `AppState`: check that `HealthChecker` and views still compile
- If adding new services: update `serviceStartupOrder` in `ServiceInfo.swift` and health checking in `HealthChecker.swift`
- If changing bridge API: update `BridgeTypes.swift` models and corresponding `AppleContainerRuntime` in content-manager repo

## CI/CD
- CI runs on GitHub Actions (macos-15 runner): `swift build` + `swift test`
- Release job: builds release binary, creates app bundle, signs, creates DMG, notarizes, publishes to GitHub Releases
- Requires secrets: `CERTIFICATE_P12`, `CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_PASSWORD`, `TEAM_ID`
