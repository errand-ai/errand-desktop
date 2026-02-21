# ErrandDesktop — Style & Conventions

## Swift Version & Concurrency
- Swift 6.1 with strict concurrency checking
- All types must be `Sendable`
- UI-facing state uses `@MainActor` (e.g. `AppState`, `HealthChecker`, `UpdateChecker`)
- Background managers use `actor` isolation (e.g. `ContainerEngine`, `BridgeServer`, `LiteLLMManager`, `MigrationRunner`)
- Async/await throughout; avoid completion handlers

## Naming
- Types: `PascalCase` (e.g. `ServiceInfo`, `ContainerEngine`, `BridgeServer`)
- Properties/methods: `camelCase` (e.g. `startAll()`, `containerIP`, `healthCheckFailures`)
- Enums: `PascalCase` type, `camelCase` cases (e.g. `ServiceStatus.running`)
- File names match primary type (e.g. `ContainerEngine.swift` contains `class ContainerEngine`)

## Documentation
- `///` doc comments on public types, properties, and methods
- `// MARK: -` sections to organize large files (e.g. `// MARK: - TCP Health Check`)
- Inline `//` comments for non-obvious logic
- No excessive documentation on self-explanatory code

## Code Organization
- One primary type per file (with small related types allowed, e.g. `LogEntry` in `AppState.swift`)
- Files grouped by concern into subdirectories: `App/`, `Models/`, `Container/`, `Bridge/`, `Views/`, `Storage/`, `LiteLLM/`, `Migration/`
- Models are simple value types (`struct`, `enum`) conforming to `Codable`/`Sendable`/`Identifiable` as needed

## Patterns
- `@Published` properties on `AppState` for SwiftUI reactivity
- Services tracked as `[ServiceInfo]` array with index-based mutation
- Error handling: `do/catch` with logging via `print()` (no formal logging framework yet)
- Health checks: TCP via `NWConnection`, HTTP via `URLSession`
- Bridge server: raw TCP via `NWListener` with manual HTTP parsing (no third-party HTTP framework)
- Container IDs tracked in dictionaries (`containers`, `taskContainers`, `taskContainerExitStatus`)

## Access Control
- Default (internal) access for most types — single-module app
- `private` for implementation details
- `private(set)` for properties that should be readable but not externally settable

## Error Types
- Custom error enums conforming to `LocalizedError` (e.g. `ContainerEngineError`, `BridgeServerError`)
- `errorDescription` computed property for human-readable messages
