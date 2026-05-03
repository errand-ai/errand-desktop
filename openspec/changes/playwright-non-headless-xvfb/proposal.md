## Why

Some websites detect and block headless browsers via navigator properties, canvas fingerprinting, and WebGL capability checks. Running Playwright in non-headless (headed) mode with Xvfb provides a real rendering pipeline that bypasses these detection mechanisms. The official `playwright/mcp` image already ships with Xvfb and X11 libraries — no custom image build is needed.

This is the errand-desktop counterpart to the same change in the errand backend repo (which covers Docker Compose and Helm configs). This change covers the macOS desktop app's container engine.

## What Changes

- Override the Playwright MCP container entrypoint to start Xvfb before the MCP server process (both Docker and Apple Containerization runtimes)
- Remove the `--headless` flag from the command args
- Set `DISPLAY=:99` environment variable for the Xvfb virtual display
- Add `ShmSize` support to `ContainerConfig` and `DockerRuntime` for Chrome shared memory (2GB)
- The entrypoint becomes a shell command: `sh -c "Xvfb :99 ... & sleep 1 && DISPLAY=:99 exec node /app/cli.js ..."`

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

_(errand-desktop does not have existing openspec specs for playwright — the changes are implementation-only in ContainerEngine.swift)_

## Impact

- **Code**: `Sources/ErrandDesktop/Container/ContainerEngine.swift` (command override for playwright), `ContainerRuntime.swift` (add shmSize to ContainerConfig), `DockerRuntime.swift` (pass ShmSize in HostConfig)
- **Resource usage**: ~100-150MB more memory per Playwright container, plus 2GB shared memory allocation
- **No protocol changes**: The Playwright MCP server interface and port remain identical
