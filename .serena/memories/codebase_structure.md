# ErrandDesktop — Codebase Structure

```
Package.swift                          # Swift Package (macOS 26+, swift-containerization dep)
ErrandDesktop.entitlements             # com.apple.security.virtualization

Sources/ErrandDesktop/
├── App/
│   ├── ErrandDesktopApp.swift         # @main entry, MenuBarExtra + windows
│   ├── AppState.swift                 # @MainActor ObservableObject, orchestrates all managers
│   └── UpdateChecker.swift            # GitHub Releases API check, semver compare, notifications
├── Models/
│   ├── ServiceInfo.swift              # ServiceStatus/AppStatus enums, ServiceInfo struct, startup order
│   ├── AppConfig.swift                # Codable config struct (ports, API keys, OIDC, flags)
│   └── BridgeTypes.swift              # Request/response types for bridge API
├── Container/
│   ├── ContainerEngine.swift          # actor: OCI pull, container create/start/stop, health checks
│   └── HealthChecker.swift            # @MainActor: periodic TCP/HTTP health monitoring
├── Bridge/
│   ├── BridgeServer.swift             # actor: NWListener HTTP server on localhost:9876
│   └── HTTPTypes.swift                # HTTPRequest parser + HTTPResponse builder
├── Storage/
│   └── StorageManager.swift           # ~/Library/Application Support/ErrandDesktop/ management
├── LiteLLM/
│   └── LiteLLMManager.swift           # actor: optional LiteLLM container + config.yaml generation
├── Migration/
│   └── MigrationRunner.swift          # actor: Alembic migration via container exec
└── Views/
    ├── MenuBarPopover.swift            # Service status list, start/stop/open buttons
    ├── SettingsView.swift              # TabView: General, LLM, OIDC, Ports
    ├── LogViewerView.swift             # Filtered log list with auto-scroll
    ├── SetupAssistantView.swift        # 5-step first-run wizard
    └── LiteLLMConfigView.swift         # LiteLLM provider list editor

Tests/ErrandDesktopTests/              # (empty — tests not yet written)

.github/workflows/build.yml           # CI: build+test, release (sign, notarize, DMG, GitHub Release)
scripts/create-dmg.sh                  # hdiutil DMG creation with Applications symlink
docs/signing-setup.md                  # Developer ID certificate setup guide
```

## Key Files by Concern

| Concern | File(s) |
|---------|---------|
| App lifecycle | `ErrandDesktopApp.swift`, `AppState.swift` |
| Container management | `ContainerEngine.swift` |
| Bridge API server | `BridgeServer.swift`, `HTTPTypes.swift` |
| Health monitoring | `HealthChecker.swift` |
| Data models | `ServiceInfo.swift`, `AppConfig.swift`, `BridgeTypes.swift` |
| Persistence | `StorageManager.swift` |
| LiteLLM | `LiteLLMManager.swift` |
| Migrations | `MigrationRunner.swift` |
| UI | `Views/*.swift` |
| Distribution | `.github/workflows/build.yml`, `scripts/create-dmg.sh` |
