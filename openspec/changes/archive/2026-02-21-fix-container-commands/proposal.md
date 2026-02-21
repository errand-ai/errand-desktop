## Why

The errand-backend Docker image serves three distinct roles — database migration, API server, and worker — each requiring a different startup command. Currently, errand-desktop launches both the backend and worker containers using the image's default CMD (`uvicorn main:app`), meaning the worker is incorrectly running as a second API server instead of executing `python worker.py`. There is also no database migration step, so schema changes are never applied (the `AUTO_MIGRATE=true` env var is a workaround that doesn't use the standard Alembic migration path).

## What Changes

- Add a new **migrate** service that runs `alembic upgrade head` using the errand-backend image, executed after Postgres is healthy and before the backend starts
- Override the worker container's command to run `python worker.py` instead of the image's default `uvicorn` CMD
- Remove the `AUTO_MIGRATE=true` env var from the backend since migrations will be handled by the dedicated migrate container
- Add the `createAndStartContainer` method's ability to accept a custom command override (the Containerization framework's `config.process.arguments` property)
- Update `serviceStartupOrder` to include the migrate step between postgres and backend
- The migrate container is ephemeral — it runs to completion and is cleaned up before proceeding

## Capabilities

### New Capabilities
- `container-commands`: Ability to specify custom startup commands per container, and to run ephemeral (run-to-completion) containers as part of the service lifecycle

### Modified Capabilities

## Impact

- **ContainerEngine.swift**: `createAndStartContainer` gains an optional `command` parameter; `startAll` must handle ephemeral containers that run to completion rather than staying alive
- **ServiceInfo.swift**: `serviceStartupOrder` updated; new `migrate` service added; `ServiceInfo` may need a field to indicate ephemeral vs long-running
- **AppState.swift**: Must track the migrate service and handle its run-to-completion lifecycle
- **HealthChecker.swift**: Migrate service uses exit-code-based health (exit 0 = success) rather than ongoing health checks
