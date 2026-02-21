## 1. Add command override to ContainerEngine

- [x] 1.1 Add optional `command: [String]?` parameter to `createAndStartContainer`. When non-nil, set `config.process.arguments = command` in the container config closure.

## 2. Add migrate service and update startup order

- [x] 2.1 Add `ServiceInfo` for "migrate" with `displayName: "Migrate"`. Add an `isEphemeral: Bool` property to `ServiceInfo` (default `false`, `true` for migrate).
- [x] 2.2 Update `serviceStartupOrder` to `[["postgres"], ["migrate", "valkey"], ["backend"], ["worker"]]`.
- [x] 2.3 Add `"migrate"` case to `imageSpecs` — uses same image as backend/worker: `ghcr.io/errand-ai/errand-backend:{tag}`.
- [x] 2.4 Add `"migrate"` case to `buildEnv` — only needs `DATABASE_URL` pointing to postgres IP.

## 3. Handle ephemeral containers in startAll

- [x] 3.1 In `startAll`, after creating and starting an ephemeral container, call `container.wait()` to wait for exit instead of health-checking. On exit code 0, clean up the container (stop, delete, remove from maps). On non-zero exit, throw an error.
- [x] 3.2 Pass `command: ["alembic", "upgrade", "head"]` when starting the migrate service.
- [x] 3.3 Pass `command: ["python", "worker.py"]` when starting the worker service.

## 4. Clean up backend env

- [x] 4.1 Remove `env["AUTO_MIGRATE"] = "true"` from the `"backend"` case in `buildEnv`.

## 5. Update AppState and UI

- [x] 5.1 Add the migrate `ServiceInfo` to the services array in `AppState`. Handle the ephemeral lifecycle (show "Migrating..." during run, "Completed" or "Error" after).
- [x] 5.2 Update `stopAll` to skip the migrate service (it's already cleaned up after running).
