## Why

The Apple Developer App ID has been registered as `sh.errand.desktop`. The codebase currently uses a mix of `com.errand.*` and `io.errand.*` identifiers. These must be standardized to `sh.errand.*` to match the registered App ID, and the CI pipeline needs fixes to produce a correctly structured app bundle.

## What Changes

- **BREAKING**: CFBundleIdentifier changes from `com.errand.desktop` to `sh.errand.desktop`
- Update Keychain service name from `io.errand.ErrandDesktop` to `sh.errand.ErrandDesktop`
- Update dispatch queue labels to use `sh.errand.*` prefix
- Update CLAUDE.md reference to old Keychain service name
- Fix CI app bundle to include resource bundles in `Contents/Resources/`

## Capabilities

### New Capabilities

_None_

### Modified Capabilities

_None_ (these are identifier/CI changes, not behavioral)

## Impact

- **Source files**: `KeychainManager.swift`, `BridgeServer.swift`, `PortForwarder.swift`
- **CI**: `.github/workflows/build.yml` — Info.plist CFBundleIdentifier, resource bundle copying
- **Docs**: `CLAUDE.md` references old Keychain service name
- **User-facing**: Users who ran previous builds will have an orphaned Keychain item under the old service name
