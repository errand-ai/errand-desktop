## Context

errand-desktop manages Playwright as a standalone container service via `ContainerEngine.swift`. It supports two runtimes: Docker (via Docker Engine API) and Apple Containerization (native macOS virtualization). The `commandOverride(for:)` method currently returns:

- **Docker**: `["--isolated", "--port", "3000", "--host", "0.0.0.0", "--allowed-hosts", "*"]` (appended to image entrypoint)
- **Apple**: `["node", "/app/cli.js", "--isolated", "--port", "3000", "--host", "0.0.0.0", "--allowed-hosts", "*"]` (full command, no entrypoint mechanism)

The official image's entrypoint is `["node", "cli.js", "--headless", "--browser", "chromium", "--no-sandbox"]`. Since we need to override the entrypoint entirely (to inject Xvfb startup), both runtimes will use a shell command approach.

## Goals / Non-Goals

**Goals:**
- Run Playwright in non-headless mode with Xvfb on both Docker and Apple runtimes
- Add shared memory support (`ShmSize`) to `ContainerConfig` and `DockerRuntime`
- Keep the same MCP port and URL interface

**Non-Goals:**
- VNC/noVNC debugging access
- Custom Playwright image builds

## Decisions

### Decision: Shell command entrypoint for both runtimes

Both runtimes use a shell script that scrubs stale X11 lock/socket files, starts Xvfb in the background, polls `/tmp/.X11-unix/X99` until the display socket appears (with a fail-fast if it doesn't), and then `exec`s the MCP server:

```sh
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null
Xvfb :99 -screen 0 1920x1080x24 -ac -nolisten tcp &
for i in $(seq 1 50); do [ -S /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
[ -S /tmp/.X11-unix/X99 ] || { echo 'Xvfb failed to create display socket' >&2; exit 1; }
DISPLAY=:99 exec node /app/cli.js --browser chromium --no-sandbox --isolated --port 3000 --host 0.0.0.0 --allowed-hosts '*'
```

The lock-scrub is needed because Apple Containerization reuses the rootfs across container restarts, so `/tmp/.X99-lock` and the unix socket from a previous Xvfb survive even though the process does not — leading to "Server is already active for display 99".

For Docker we also need to clear the image's entrypoint. The Docker Engine API takes an `Entrypoint` field in the create body, but `ContainerConfig` previously only had a `command` field (mapped to `Cmd`).

**Approach**: Add an `entrypoint` field to `ContainerConfig` (optional, Docker-only). When set, `DockerRuntime.createContainer` includes `"Entrypoint"` in the JSON body.

- **Docker**: `entrypoint = ["sh", "-c"]` and `command = [<script>]` (the script is a single argument to `sh -c`). Setting `command = ["sh", "-c", <script>]` would pass `<script>` as `$0` rather than executing it.
- **Apple**: no entrypoint mechanism is available, so the full `["sh", "-c", <script>]` is passed as the `command` and the runtime invokes it directly.

### Decision: Add shmSize to ContainerConfig

Add an optional `shmSize: Int64?` field to `ContainerConfig`. When non-nil, `DockerRuntime.createContainer` includes `"ShmSize": shmSize` in `HostConfig`. Set to `2 * 1024 * 1024 * 1024` (2GB) for Playwright.

Apple Containerization doesn't need this — the runtime handles shared memory differently.

### Decision: ContainerEngine changes

In `commandOverride(for:)` and a new `entrypointOverride(for:)` method (or equivalent), return the Xvfb shell command for playwright. The `containerConfig(for:)` method sets `shmSize` for playwright when using Docker runtime.

## Risks / Trade-offs

- **Entrypoint override complexity** → Adding `entrypoint` to `ContainerConfig` is a small protocol change but only affects Docker runtime
- **Apple runtime Xvfb** → The Apple Containerization Linux VM should support Xvfb since it's a standard Linux environment; needs verification
