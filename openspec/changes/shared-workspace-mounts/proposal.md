# Shared Workspace Mounts (Desktop side)

## Why

The errand server's `shared-cloud-workspace` change (errand repo, `openspec/changes/shared-cloud-workspace/`) lets opted-in task profiles mount a `/shared` directory that is a live view of a Google Drive or OneDrive folder, because local LLMs reliably handle filesystem operations but consistently fail with the `gws` CLI (production evidence: 58 "Untitled" files in Drive root from malformed create calls). On Errand-Desktop the native Drive/OneDrive sync client already provides that live view locally — the missing piece is the desktop app's side of the contract: accepting a `mounts` field on the bridge container-create API and attaching the approved host directory to task containers.

## What Changes

- **Bridge API**: `POST /containers` accepts an optional `mounts` array (`host_path`, `container_path`); each entry is attached to the task container read-write. Absent `mounts` → behavior unchanged.
- **Mount validation**: the app maintains a single user-approved shared workspace directory; the bridge rejects any requested `host_path` that does not resolve to that directory or a subpath of it (symlinks resolved, traversal blocked). No approved directory configured → all mount requests rejected.
- **Runtime plumbing**: `ContainerEngine.createTaskContainer` and both `ContainerRuntime` implementations pass task mounts through — virtiofs `.share` on Apple Containerization, bind mounts on Docker (both mechanisms already exist for service containers; this extends them to the task-container path).
- **Workspace directory setting**: settings UI gains a shared-workspace folder picker (e.g. `~/Google Drive/My Drive/Errand`); the chosen path is stored in `AppConfig` and advertised to the Worker container via a new env var so the errand server can construct valid mount requests.
- **Mirrored-files guidance**: settings surface warns that the chosen folder must be locally materialized ("Mirror files" mode) — File Provider dataless placeholders do not materialize reliably through virtiofs.

## Capabilities

### New Capabilities

- `bridge-workspace-mounts`: the `mounts` field on the bridge container-create API, including validation against the approved directory.
- `workspace-directory-config`: the approved-directory setting — folder picker UI, `AppConfig` persistence, Worker env var advertisement, mirrored-files guidance.

### Modified Capabilities

- `container-runtime-abstraction`: task-container creation accepts mount specifications alongside image/env/files.
- `docker-runtime`: task containers receive requested mounts as bind mounts (extends the existing volume-mount requirement to the task path).

## Impact

- **Code**: `Bridge/BridgeServer.swift` (+ request model in `HTTPTypes.swift`/models), `Container/ContainerEngine.swift`, `Container/AppleContainerRuntime.swift`, `Container/DockerRuntime.swift`, `Models/AppConfig.swift`, settings view, Worker env var injection.
- **Contract**: matches the `container-bridge-api` delta spec in the errand repo's `shared-cloud-workspace` change — the two changes must agree on the `mounts` payload shape.
- **Security**: the approved-directory check is the desktop's enforcement boundary — the Worker container is untrusted input to the bridge; a compromised worker must not be able to mount arbitrary host paths (e.g. `~/.ssh`).
- **No breaking changes**: payloads without `mounts` behave exactly as today.
