## Context

The errand-backend Docker image has a default CMD of `uvicorn main:app --host 0.0.0.0 --port 8000 ...`. In the docker-compose setup, the `migrate` service overrides this with `alembic upgrade head` and the `worker` service overrides with `python worker.py`. The errand-desktop app currently has no mechanism to override the container command, so both backend and worker run the default uvicorn server.

The Containerization framework's container config exposes `config.process.arguments` which sets the process arguments (i.e. the command to run). This is the lever we need to use.

## Goals / Non-Goals

**Goals:**
- Run `alembic upgrade head` in an ephemeral migrate container before starting the backend
- Run `python worker.py` as the worker container's command
- Let the backend run its default CMD (uvicorn) with no override
- Keep the migrate container lifecycle clean: start, wait for exit 0, clean up, proceed

**Non-Goals:**
- Changing the container image build process
- Adding a generic "job runner" framework — just handle the migrate case
- Supporting arbitrary user-defined init containers

## Decisions

### 1. Add `command` parameter to `createAndStartContainer`

Add an optional `command: [String]?` parameter. When provided, set `config.process.arguments = command` in the container config closure. This overrides the image's default CMD/ENTRYPOINT.

### 2. Model migrate as a service in `serviceStartupOrder`

Insert `["migrate"]` between `["postgres"]` and `["valkey"]` in `serviceStartupOrder`. Actually, migrate depends on postgres being healthy but doesn't need valkey — so it goes right after postgres, before valkey:

```
["postgres"] → ["migrate"] → ["valkey"] → ["backend"] → ["worker"]
```

Wait — migrate only needs postgres. But valkey doesn't depend on migrate. So we can run migrate and valkey in the same group:

```
["postgres"] → ["migrate", "valkey"] → ["backend"] → ["worker"]
```

This is faster (valkey and migrate start concurrently) and correct (neither depends on the other).

### 3. Ephemeral container handling in `startAll`

For the migrate service, instead of health-checking and keeping it running, we need to:
1. Create and start the container
2. Wait for it to exit (via `container.wait()`)
3. Check exit code — 0 means success, anything else is an error
4. Clean up the container
5. Mark the service as "completed" (not "running")

Add an `isEphemeral` flag to `ServiceInfo` to distinguish run-to-completion containers from long-running services. In `startAll`, after starting an ephemeral container, call `container.wait()` instead of health polling. On exit 0, mark as completed and clean up. On non-zero, throw an error.

### 4. Worker command override

In `startAll`, when starting the worker service, pass `command: ["python", "worker.py"]` to `createAndStartContainer`. The working directory in the image is `/app` (set by `WORKDIR /app` in the Dockerfile), so `python worker.py` will resolve correctly.

### 5. Remove AUTO_MIGRATE from backend env

Remove `env["AUTO_MIGRATE"] = "true"` from the backend case in `buildEnv`. Migrations are now handled by the dedicated migrate container.

### 6. Migrate service env vars

The migrate container needs only `DATABASE_URL` pointing to the postgres container IP. Same pattern as backend/worker.

## Risks / Trade-offs

- **Startup time**: Adding a synchronous migration step adds time to startup. Mitigated by running migrate and valkey concurrently.
- **Migration failures**: If `alembic upgrade head` fails (non-zero exit), the entire startup fails. This is the correct behaviour — the backend shouldn't start with a stale schema.
- **Container cleanup**: Ephemeral containers must be cleaned up even on failure to avoid orphaned container directories. The existing `cleanupOrphanedContainers` handles this on next launch, but we should also clean up inline.
