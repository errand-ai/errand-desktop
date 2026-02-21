# ErrandDesktop — Project Overview

## Purpose
ErrandDesktop is a native macOS menu bar application that manages the Errand (content-manager) stack locally using Apple's Containerization framework. It runs PostgreSQL, Valkey, Backend, and Worker as lightweight VM-based containers on Apple silicon Macs, with an optional LiteLLM proxy service.

## Tech Stack
- **Language**: Swift 6.1
- **Platform**: macOS 26+ (Apple silicon only — required for Containerization framework)
- **UI**: SwiftUI (`MenuBarExtra` for menu bar, windows for settings/logs/setup)
- **Container Runtime**: Apple `swift-containerization` v0.9.0+ (OCI image pull, container create/start/stop)
- **Networking**: Network.framework (`NWListener`, `NWConnection`) for bridge HTTP server and TCP health checks
- **Persistence**: `~/Library/Application Support/ErrandDesktop/` (config.json + data volumes)
- **CI/CD**: GitHub Actions (build, sign, notarize, DMG, GitHub Releases)
- **Package Manager**: Swift Package Manager

## Key Architecture Decisions
- `AppState` is `@MainActor ObservableObject` — central coordinator owning all managers
- `ContainerEngine` is an `actor` — thread-safe container lifecycle management
- `BridgeServer` is an `actor` — HTTP server using NWListener (not URLSession server, not SwiftNIO)
- Bridge API runs on `localhost:9876` with bearer token auth (UUID generated at startup)
- Worker container gets `CONTAINER_RUNTIME=apple` + bridge URL/token injected as env vars
- Services start in dependency order: Postgres → Valkey → Backend → Worker
- Health checking: TCP for Postgres/Valkey, HTTP GET /health for Backend/LiteLLM
- The app has `com.apple.security.virtualization` entitlement for running VMs

## Companion Project
The Python `AppleContainerRuntime` lives in the `errand-ai/errand-ai` repo (content-manager) at `backend/container_runtime.py`. It communicates with this app's bridge API.
