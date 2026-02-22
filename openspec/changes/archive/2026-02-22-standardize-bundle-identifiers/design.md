## Context

The Apple Developer account is set up with App ID `sh.errand.desktop`. The codebase has three identifier conventions: `com.errand.*` (CI plist, BridgeServer), `io.errand.*` (KeychainManager, PortForwarder), and now the correct `sh.errand.*`. The CI pipeline also has a bug where resource bundles are not copied into the app bundle.

## Goals / Non-Goals

**Goals:**
- Standardize all identifiers to `sh.errand.*`
- Fix CI to include resource bundles so `Bundle.module` works at runtime

**Non-Goals:**
- Migrating existing Keychain items from old service name (only development builds exist)
- Adding provisioning profile embedding to CI (separate change)
- Fixing the macOS runner version (separate concern, blocked on GitHub Actions availability)

## Decisions

**Decision: Simple find-and-replace for identifiers**
All identifier strings are hardcoded literals. Straightforward string replacement.

**Decision: Copy all *.bundle dirs to Contents/Resources/ in CI**
The Makefile already does `cp -R *.bundle` for local builds. The CI "Create app bundle" step needs the same, placing bundles in `Contents/Resources/` which is the standard macOS app bundle location. SPM's `Bundle.module` resolves bundles from the same directory as the binary OR from `../Resources/` in an app bundle.

**Decision: No Keychain migration**
Only development builds have used the old Keychain service name. Not worth adding migration logic.
