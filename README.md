# ErrandDesktop

A native macOS menu bar app that runs the [Errand](https://github.com/errand-ai/errand-ai) stack locally. Manages PostgreSQL, Valkey, Backend, and Worker as containers via either Docker (any supported Mac) or Apple's [Containerization](https://github.com/apple/swift-containerization) framework (macOS 26 + Apple silicon, no Docker required).

## Install

```bash
brew tap errand-ai/errand
brew trust errand-ai/errand          # Homebrew 6+ only; see note below
brew install --cask errand-desktop
```

These are one-time steps. After that, `brew upgrade --cask errand-desktop` keeps the
app current.

Homebrew 6 refuses to load casks from a non-official tap until you trust it — the
`brew trust` line is what grants that. On Homebrew 5 and earlier the command does not
exist and is not needed; skip it.

If you would rather not use Homebrew, download `ErrandDesktop.dmg` from the
[latest release](https://github.com/errand-ai/errand-desktop/releases/latest),
open it, and drag `ErrandDesktop.app` into `/Applications`. The DMG is signed and
notarized, so it launches without a Gatekeeper override.

## Upgrading

Homebrew is the canonical upgrade channel:

```bash
brew upgrade --cask errand-desktop
```

The app does not update itself. It checks GitHub Releases roughly once a day and
posts a notification when a newer version exists — Homebrew users run the command
above, manual installers click the notification to open the release page and
replace `/Applications/ErrandDesktop.app` with the new DMG.

## Requirements

A single universal (`arm64` + `x86_64`) build covers every supported Mac; there is
nothing architecture-specific to choose at install time.

| Hardware | macOS | Docker runtime | Apple Containerization |
| --- | --- | --- | --- |
| Apple silicon | 26+ (Tahoe) | Yes | Yes |
| Apple silicon | 15 (Sequoia) | Yes | No — requires macOS 26 |
| Intel | 15+ (Sequoia) | Yes | No — requires Apple silicon |
| Any | 14 and earlier | Not supported | Not supported |

macOS 15 (Sequoia) is the floor: the upstream `swift-containerization` package
declares its own `.macOS("15")` minimum, and SwiftPM minimums apply at link time
regardless of `@available` gating.

Docker mode needs a Docker-compatible socket — Docker Desktop, Colima, OrbStack, or
Rancher Desktop all work.

Building from source additionally requires Swift 6.2+.

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

Every tagged release publishes exactly one asset — `ErrandDesktop.dmg` — containing
a universal `.app`. The filename is a contract: the Homebrew cask in
[`errand-ai/homebrew-errand`](https://github.com/errand-ai/homebrew-errand) resolves
`releases/download/v<version>/ErrandDesktop.dmg`, so no architecture or version
suffix may be added.

CI builds, signs, notarizes, and publishes it. To reproduce locally:

```bash
# Build both slices and merge them into one universal binary
scripts/build-universal.sh .build/universal/ErrandDesktop

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
