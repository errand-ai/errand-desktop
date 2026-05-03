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

Both runtimes will use a shell command that starts Xvfb then execs the MCP server:

```swift
// Docker: override entrypoint entirely
// Apple: full command (already the pattern)
["sh", "-c", "Xvfb :99 -screen 0 1920x1080x24 -ac -nolisten tcp & sleep 1 && DISPLAY=:99 exec node /app/cli.js --browser chromium --no-sandbox --isolated --port 3000 --host 0.0.0.0 --allowed-hosts '*'"]
```

For Docker, we also need to clear the image's entrypoint. The Docker Engine API supports this via `"Entrypoint": [""]` in the create body — but this is awkward since `ContainerConfig` currently only has a `command` field (which maps to `Cmd`).

**Approach**: Add an `entrypoint` field to `ContainerConfig` (optional, Docker-only). When set, `DockerRuntime.createContainer` includes `"Entrypoint"` in the JSON body. For Docker, set `entrypoint: ["sh", "-c", "<script>"]` and leave `command` nil. For Apple, set `command: ["sh", "-c", "<script>"]` as before.

### Decision: Add shmSize to ContainerConfig

Add an optional `shmSize: Int64?` field to `ContainerConfig`. When non-nil, `DockerRuntime.createContainer` includes `"ShmSize": shmSize` in `HostConfig`. Set to `2 * 1024 * 1024 * 1024` (2GB) for Playwright.

Apple Containerization doesn't need this — the runtime handles shared memory differently.

### Decision: ContainerEngine changes

In `commandOverride(for:)` and a new `entrypointOverride(for:)` method (or equivalent), return the Xvfb shell command for playwright. The `containerConfig(for:)` method sets `shmSize` for playwright when using Docker runtime.

## Risks / Trade-offs

- **Entrypoint override complexity** → Adding `entrypoint` to `ContainerConfig` is a small protocol change but only affects Docker runtime
- **Apple runtime Xvfb** → The Apple Containerization Linux VM should support Xvfb since it's a standard Linux environment; needs verification
