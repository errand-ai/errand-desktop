## 1. Standardize identifiers in source

- [x] 1.1 Update `KeychainManager.swift:7` — change service from `io.errand.ErrandDesktop` to `sh.errand.ErrandDesktop`
- [x] 1.2 Update `BridgeServer.swift:9` — change queue label from `com.errand.bridge-server` to `sh.errand.bridge-server`
- [x] 1.3 Update `PortForwarder.swift:18` — change queue label from `io.errand.port-forwarder` to `sh.errand.port-forwarder`

## 2. Update CI pipeline

- [x] 2.1 Update `build.yml:61` — change CFBundleIdentifier from `com.errand.desktop` to `sh.errand.desktop`
- [x] 2.2 Add resource bundle copying to CI "Create app bundle" step — copy `*.bundle` dirs to `Contents/Resources/`

## 3. Update docs

- [x] 3.1 Update `CLAUDE.md` — change Keychain service reference from `io.errand.ErrandDesktop` to `sh.errand.ErrandDesktop`

## 4. Verify

- [x] 4.1 Run `swift build` to confirm compilation succeeds
