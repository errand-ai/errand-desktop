# ErrandDesktop

A native macOS menu bar app that runs the [Errand](https://github.com/errand-ai/errand-ai) stack locally using Apple's [Containerization](https://github.com/apple/swift-containerization) framework. Manages PostgreSQL, Valkey, Backend, and Worker as lightweight VM-based containers on Apple silicon — no Docker required.

## Requirements

- macOS 26+ (Tahoe)
- Apple silicon (M1 or later)
- Swift 6.1+

## Features

- **Menu bar app** — status icon reflects service health (idle, starting, running, degraded)
- **One-click start/stop** — dependency-ordered startup (Postgres → Valkey → Backend → Worker) and reverse shutdown
- **Health monitoring** — TCP checks for Postgres/Valkey, HTTP health endpoints for Backend
- **Settings** — configure API keys, OIDC, ports, launch at login
- **Log viewer** — filterable, auto-scrolling log stream from all services
- **First-run wizard** — guided setup for credentials and image pulling
- **LiteLLM integration** — optional multi-provider LLM proxy service
- **Database migrations** — runs Alembic migrations automatically on startup
- **Auto-update** — checks GitHub Releases for new versions
- **Bridge API** — local HTTP server enabling the Worker to manage task-runner containers through the host app

## Building

```bash
swift build
```

## Running

```bash
swift run ErrandDesktop
```

The app appears in the menu bar. Click the tray icon to view service status and controls.

## Testing

```bash
swift test
```

## Distribution

Release builds are signed, notarized, and packaged as a DMG via CI:

```bash
# Build release binary
swift build -c release

# Create DMG (after building the app bundle)
scripts/create-dmg.sh ErrandDesktop.app ErrandDesktop.dmg
```

See [docs/signing-setup.md](docs/signing-setup.md) for Developer ID certificate configuration.

## Architecture

```
Sources/ErrandDesktop/
├── App/          # Entry point, AppState orchestrator, update checker
├── Models/       # ServiceInfo, AppConfig, BridgeTypes
├── Container/    # ContainerEngine (actor), HealthChecker
├── Bridge/       # HTTP server (NWListener) for worker ↔ host communication
├── Storage/      # Persistent config and data volume management
├── LiteLLM/      # Optional LiteLLM container management
├── Migration/    # Alembic migration runner
└── Views/        # MenuBarPopover, Settings, LogViewer, SetupAssistant
```

Key design choices:

- **`AppState`** (`@MainActor ObservableObject`) — central coordinator owning all managers
- **`ContainerEngine`** (`actor`) — thread-safe OCI image pull, container lifecycle, health checks
- **`BridgeServer`** (`actor`) — raw TCP HTTP server on `localhost:9876` with bearer token auth
- **Entitlements** — `com.apple.security.virtualization` for running lightweight VMs

## License

Private — all rights reserved.
