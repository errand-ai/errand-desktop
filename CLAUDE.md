# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ErrandDesktop is a native macOS menu bar app (Swift 6.2, macOS 26+/Tahoe, Apple silicon only) that runs the [Errand](https://github.com/errand-ai/errand-ai) stack locally using Apple's [Containerization](https://github.com/apple/swift-containerization) framework. It manages PostgreSQL, Valkey, Backend, and Worker as lightweight VM-based containers — no Docker required.

## Build & Run Commands

```bash
swift build                    # Debug build
swift build -c release         # Release build
swift test                     # Run tests
make run                       # Build, sign with entitlements, copy to /var/tmp, and launch
make stop                      # Kill running instance
make clean                     # Clean build artifacts and /var/tmp copy
```

The `make run` workflow is required for actual testing because the app needs the `com.apple.security.virtualization` entitlement (in `ErrandDesktop.entitlements`) to create VMs, and vmnet requires running from `/var/tmp` rather than the `.build` directory.

Debug logs go to `/tmp/errand-debug.log` since `print()` output is not visible in menu bar apps.

## Architecture

### Concurrency Model

- **`AppState`** (`@MainActor ObservableObject`) — Central coordinator. Owns all managers, publishes service state and logs to SwiftUI views. All UI-facing state flows through here.
- **`ContainerEngine`** (`actor`) — Thread-safe OCI image pulling, container create/start/stop, health checks, and exec. Uses Apple's `Containerization` framework (`ContainerManager`, `ImageStore`, `LinuxContainer`). Manages both long-running service containers and short-lived task-runner containers.
- **`BridgeServer`** (`actor`) — Raw TCP HTTP/1.1 server on `localhost:9876` using `NWListener`. Authenticates via bearer token. Enables the Worker container to create/manage task-runner containers through the host app. Supports SSE for log streaming.
- **`PortForwarder`** — TCP proxy using `NWListener`/`NWConnection` that forwards localhost ports to container VM IPs, since vmnet doesn't automatically expose container ports to the host.

### Service Lifecycle

Services start in dependency order defined in `serviceStartupOrder` (ServiceInfo.swift): Postgres → Valkey → Backend → Worker. Each group waits for health checks before the next starts. Shutdown is reverse order. LiteLLM is optionally inserted before Backend.

Container startup per service: pull image → create container (with env vars, mounts) → start → poll health checks (exec-based for Postgres/Valkey, HTTP for Backend, passthrough for Worker) → mark running.

### Storage Layout

All persistent data lives under `~/Library/Application Support/ErrandDesktop/`:
- `config.json` — User settings (`AppConfig`)
- `data/disks/postgres.img`, `data/disks/valkey.img` — ext4 block device images (created via `ContainerizationEXT4`)
- `data/litellm/` — LiteLLM config.yaml and providers.json
- `kernel/vmlinux` — Cached Kata Containers kernel binary (downloaded on first run)

Postgres and Valkey use ext4 block devices (not virtiofs shares) because they need full filesystem control (chown, chmod).

### Bridge API

The BridgeServer exposes a REST API for the Worker to manage task-runner containers:
- `POST /containers` — Create and start a task container
- `GET /containers/{id}/status` — Poll container status
- `GET /containers/{id}/logs` — SSE log stream
- `GET /containers/{id}/output` — Read /output/result.json
- `DELETE /containers/{id}` — Stop and remove

HTTP parsing is hand-rolled in `HTTPTypes.swift` (no external HTTP server dependency). Auth token is generated at startup and injected into the Worker via `CONTAINER_BRIDGE_TOKEN` env var.

### Keychain Integration

`KeychainManager` stores the credential encryption key in the macOS Keychain (service: `sh.errand.ErrandDesktop`). This key is injected into Backend/Worker containers as `CREDENTIAL_ENCRYPTION_KEY`.

## Key Conventions

- All types are `Sendable`. The codebase uses Swift 6 strict concurrency.
- Actors for thread safety (`ContainerEngine`, `BridgeServer`, `LiteLLMManager`, `MigrationRunner`), `@MainActor` for UI state (`AppState`, `HealthChecker`).
- Container IDs are prefixed: `errand-` for service containers, `task-` for bridge API task-runner containers.
- The app is a `MenuBarExtra` with `.window` style — no dock icon (`LSUIElement = true`).
- Resources (menu bar icons) are in `Sources/ErrandDesktop/Resources/` and accessed via `Bundle.module`.

## CI

GitHub Actions (`.github/workflows/build.yml`): builds on macOS 15, runs tests, then for main/tags creates a signed+notarized DMG release.

## Serena (Code Intelligence)

This project uses a Serena MCP server for semantic code navigation. Config: `.serena/project.yml`

- Languages: Python (pylsp) + Vue — Python listed first so `.py` files use pylsp, not Vue LSP
- `pylsp` is installed into Serena's uv-managed Python, not the system Python
- After changing `.serena/project.yml`, restart Serena via `/mcp` in Claude Code, then `activate_project`
- Verify Python LSP: `get_symbols_overview` on a `.py` file should return Python symbols, not `{"Module": ["script setup"]}`

## Memory (Hindsight)

This project uses a [Hindsight](https://hindsight.vectorize.io) MCP server for persistent memory across conversations. The server is configured as `hindsight` in Claude Code's MCP settings, connected to the `claude-code` memory bank at `https://hindsight.coward.cloud/mcp/claude-code/`.

**You must use Hindsight for all memory operations in this project — do not use local auto-memory files.**

### When to store memories (retain)

- After completing a significant change or implementation
- When discovering important architectural decisions, patterns, or conventions
- When learning project-specific gotchas, workarounds, or debugging insights
- When the user explicitly asks you to remember something

### When to recall memories

- **At the start of every conversation**: recall relevant context about the project, recent changes, and conventions
- Before starting any non-trivial task: recall related past work, decisions, and patterns
- When the user references something from a previous session

### Tools

- **`mcp__hindsight__retain`** — Store a memory. Provide a clear, factual `content` string. Use `context` to categorize (e.g. `"architecture"`, `"conventions"`, `"decisions"`, `"debugging"`).
- **`mcp__hindsight__recall`** — Search memories. Provide a natural language `query`. Use `max_results` to control how many results to retrieve.

### Debugging

- Hindsight REST API is available at `https://hindsight.coward.cloud/api/` (e.g. `/api/banks` lists memory banks)

