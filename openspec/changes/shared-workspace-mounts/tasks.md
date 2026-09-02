# Tasks — shared-workspace-mounts

## 1. UID-mapping harness test (gates the rest — design OQ1)

- [ ] 1.1 Small harness: create a task container on Apple Containerization with a virtiofs share of a test folder; verify UID 65532 can read and write files, and resulting host file ownership is acceptable (no chmod of the user folder required)
- [ ] 1.2 Repeat on the Docker runtime (bind mount); document any UID-mapping differences
- [ ] 1.3 Record verdict in design.md (R3): proceed as designed, or specify virtiofs UID-mapping options needed on the Apple path

## 2. Config and validation core

- [ ] 2.1 Add `sharedWorkspacePath: String?` to `AppConfig` with persistence in `config.json`
- [ ] 2.2 Implement mount validation (standardize + resolve symlinks, prefix containment, absolute `container_path`, reserved-path rejection, reject-all when unset) as a pure, unit-testable function
- [ ] 2.3 Unit tests: traversal (`..`), symlink escape, exact-match approved dir, subpath accept, unset config, reserved container paths (`/workspace`, `/output`, `/app`)

## 3. Bridge API

- [ ] 3.1 Add `mounts: [MountRequest]?` (`host_path`, `container_path`) to `CreateContainerRequest`
- [ ] 3.2 `handleCreateContainer`: run validation before container creation; structured error response on rejection; pass validated mounts to `ContainerEngine`
- [ ] 3.3 Bridge tests: create-with-mounts success, each rejection case returns an error and creates no container, payload without `mounts` unchanged

## 4. Runtime plumbing

- [ ] 4.1 `ContainerEngine.createTaskContainer`: accept mounts parameter, thread through to the runtime alongside scratch workspace/output mounts
- [ ] 4.2 AppleContainerRuntime: append task mounts as `.share` virtiofs entries (with any UID-mapping options from task 1.3)
- [ ] 4.3 DockerRuntime: append task mounts as read-write `Binds`
- [ ] 4.4 Tests: both runtimes produce expected mount configuration; no-mounts path identical to current behavior

## 5. Worker env advertisement

- [ ] 5.1 Inject `SHARED_WORKSPACE_HOST_DIR` into Worker env when configured; omit when unset
- [ ] 5.2 Test: Worker env contents with and without the setting

## 6. Settings UI

- [ ] 6.1 Shared Workspace settings section: folder picker (NSOpenPanel), current path display, clear control
- [ ] 6.2 Mirrored-files guidance note ("Mirror files" / "Always keep on this device") and Worker-restart-required note
- [ ] 6.3 UI behavior: selection persists across restart; clearing reverts bridge to reject-all

## 7. End-to-end verification

- [ ] 7.1 `make run` with a configured workspace folder inside the local Google Drive sync directory; run a workspace-enabled task from the errand backend; verify the task reads and writes files at `/shared` and edits appear in Drive via the sync client
- [ ] 7.2 Verify a payload requesting a path outside the approved directory is rejected end-to-end (worker → bridge)
- [ ] 7.3 `swift test` green; update README/docs with the feature, its opt-in nature, and the mirrored-files requirement
