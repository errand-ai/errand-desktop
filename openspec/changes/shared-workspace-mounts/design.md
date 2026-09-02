# Shared Workspace Mounts — Design

## Context

The errand server's `shared-cloud-workspace` change defines a `mounts` field on the bridge `POST /containers` payload; ErrandDesktop must implement it. Current state:

- `BridgeServer.handleCreateContainer` decodes `CreateContainerRequest` and calls `ContainerEngine.createTaskContainer(image:env:files:)` — no mount support on the task path.
- Task containers already use host-directory mounts internally (scratch `workspace/` and `output/` dirs under `~/Library/Application Support/ErrandDesktop/`), so both runtimes have working mount mechanics: `Containerization.Mount.share` (virtiofs) on Apple, bind mounts on Docker.
- The Worker container is authenticated to the bridge via bearer token, but its *requests* are untrusted from the host's perspective: the mount feature must not let a compromised worker mount arbitrary host paths.
- On desktop, the live cloud view comes from the native Google Drive / OneDrive sync client — no rclone gateway is deployed. The app only shares a local folder.

## Goals / Non-Goals

**Goals:**

- Implement the bridge `mounts` contract exactly as specced in the errand repo (`container-bridge-api` delta): optional array of `{host_path, container_path}`, read-write, per-container.
- Enforce a single user-approved workspace directory as the boundary for all task mounts.
- Advertise the approved directory to the Worker so the server can construct mount requests without guessing host paths.
- Identical behavior on both desktop runtimes (Apple Containerization and Docker).

**Non-Goals:**

- Running an rclone gateway on desktop (native sync clients own the cloud sync).
- Multiple approved directories or per-profile approval UI on desktop (v1: one directory; profile subpaths are the server's concern and arrive as subpath'd `host_path`s).
- Enforcing Drive/OneDrive "mirror files" mode programmatically — v1 documents and warns; detection heuristics are out of scope.
- Sandboxing changes: the app is not App Sandbox-enabled today; security-scoped bookmarks are noted as future-proofing only.

## Decisions

### D1. Payload shape mirrors the server-side contract verbatim

`CreateContainerRequest` gains `mounts: [MountRequest]?` where `MountRequest` is `{host_path: String, container_path: String}` (snake_case to match the existing bridge payload style). Missing/empty → no mounts, identical behavior to today. This is the same shape the errand server's `AppleContainerRuntime.prepare()` will send; any change must be coordinated across both repos.

### D2. Single approved directory, validated by resolved-path prefix

`AppConfig` gains `sharedWorkspacePath: String?`. Validation in the bridge (not in ContainerEngine, so rejection happens before any container is created):

1. Reject all mounts if `sharedWorkspacePath` is nil.
2. Canonicalize both the approved dir and each `host_path` (`URL.standardizedFileURL` + resolving symlinks) and require the resolved `host_path` to equal or be under the resolved approved dir.
3. Reject `container_path`s that are not absolute or that collide with reserved paths (`/workspace`, `/output`, `/app`).

Rationale: prefix-check-after-resolution is the standard defense against `../` and symlink escapes; a compromised Worker holding the bridge token must not be able to mount `~/.ssh`. **Alternative considered**: validating in ContainerEngine — rejected because the bridge is the trust boundary and the engine is also used for trusted service containers.

### D3. Approved directory advertised to the Worker via env var

When starting the Worker service container, the app injects `SHARED_WORKSPACE_HOST_DIR=<sharedWorkspacePath>` (omitted when unset). The errand server uses it as the mount-source root and appends the profile subpath. This keeps the desktop app the single source of truth; the server never invents host paths. **Alternative considered**: a bridge discovery endpoint (`GET /workspace`) — more moving parts for the same information; env var matches how the bridge URL/token are already conveyed.

### D4. Runtime plumbing reuses existing mount mechanics

`createTaskContainer` gains a `mounts` parameter appended to the same per-runtime structures the scratch workspace/output mounts already use: `.share(source:destination:)` virtiofs on Apple, `Binds` on Docker. No permission tricks beyond what the scratch dirs already do (world-writable handling exists for UID-mapping-limited systems; the shared folder is mounted as-is — UID 65532 writes rely on virtiofs/Docker default mapping, verified in testing).

### D5. Settings UI: folder picker with mirrored-files warning

Settings gains a "Shared Workspace" row: NSOpenPanel folder picker, display of the chosen path, clear button, and a persistent caution note: the folder must be locally available ("Mirror files" in Google Drive; "Always keep on this device" in OneDrive) because dataless File Provider placeholders won't materialize through virtiofs. Changing the path takes effect for subsequently created task containers; a Worker restart is required for the env var to update (the UI says so).

## Risks / Trade-offs

- **[R1] Compromised Worker attempts arbitrary host mounts** → D2 boundary validation at the bridge; unit tests cover traversal, symlink escape, unset-directory, and reserved-container-path cases.
- **[R2] Dataless placeholders (streaming mode) yield empty/failed reads inside the container** → D5 warning in UI + docs; if user reports persist, a future change can add a dataless-file detection heuristic (e.g. check `NSURLUbiquitousItemDownloadingStatus`-equivalents) — out of scope for v1.
- **[R3] UID mismatch: container UID 65532 cannot write the shared folder through virtiofs** → verify during implementation on both runtimes; the scratch-dir world-writable precedent exists if needed, but chmod'ing the user's Drive folder is unacceptable — if writes fail, the Apple runtime mount must use virtiofs UID mapping options instead; treat as a blocking implementation question on the Apple path.
- **[R4] Contract drift between repos** → both changes reference the same payload shape; the errand-repo `container-bridge-api` delta spec is the canonical contract and this design links to it.
- **[R5] Env var requires Worker restart when the path changes** → acceptable; UI communicates it. Not worth a live-reload mechanism for v1.

## Migration Plan

1. Ship behind the absence of configuration: with `sharedWorkspacePath` unset, the bridge rejects mounts and the Worker gets no env var — all existing behavior unchanged.
2. User configures the folder in settings, restarts services (or the app), then enables workspace on task profiles in the errand UI.
3. Rollback: clear the setting; mount requests are rejected again and the server-side task-manager falls back to running tasks without the mount (its specced degraded path — warning transcript event).

## Open Questions

- **OQ1**: Does virtiofs on Apple Containerization map the container's UID 65532 writes acceptably onto the host user's files (R3)? Must be answered by a small harness test before the settings UI work proceeds.
- **OQ2**: Should the mirrored-files warning be a one-time alert on folder selection, a persistent settings note, or both? (Leaning both; decide during UI implementation.)
