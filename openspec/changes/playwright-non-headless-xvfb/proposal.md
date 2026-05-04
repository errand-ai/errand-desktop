## Why

Some websites detect and block headless browsers via navigator properties, canvas fingerprinting, and WebGL capability checks. Running Playwright in non-headless (headed) mode with Xvfb provides a real rendering pipeline that bypasses these detection mechanisms. The official `playwright/mcp` image already ships with Xvfb and X11 libraries — no custom image build is needed.

This is the errand-desktop counterpart to the same change in the errand backend repo (which covers Docker Compose and Helm configs). This change covers the macOS desktop app's container engine.

## What Changes

- Override the Playwright MCP container entrypoint to start Xvfb before the MCP server process (both Docker and Apple Containerization runtimes)
- Remove the `--headless` flag from the command args
- Set `DISPLAY=:99` for the Xvfb virtual display
- Add `ShmSize` support to `ContainerConfig` and `DockerRuntime` for Chromium shared memory (2 GiB)
- Add `Entrypoint` support to `ContainerConfig` and `DockerRuntime` so we can fully replace the image entrypoint on Docker
- The startup script scrubs any stale `/tmp/.X99-lock` and `/tmp/.X11-unix/X99` (Apple Containerization reuses the rootfs across restarts), launches Xvfb in the background, polls `/tmp/.X11-unix/X99` for up to ~5 s with a fail-fast if the socket never appears, then `exec`s the node MCP server with `DISPLAY=:99`
- Make `backend` depend on `playwright` so `PLAYWRIGHT_MCP_URL` points at a healthy listener by the time the backend container is created

## Capabilities

### New Capabilities

- `playwright-service` — first canonical openspec capturing the Playwright MCP container service: image, startup args, Xvfb display setup, X11 socket readiness check, 2 GiB `shm_size`, TCP-based health check on port 3000, dependency wave, and `PLAYWRIGHT_MCP_URL` injection into the backend.

### Modified Capabilities

- `container-runtime-abstraction` — add `entrypoint` and `shmSize` fields to the runtime-agnostic `ContainerConfig`; document Docker honoring `Entrypoint` and `ShmSize`.
- `cloud-storage-desktop-services` — clarifies env-var injection targets after the worker→backend merge already on main.
- New change-only spec at `openspec/changes/playwright-non-headless-xvfb/specs/docker-runtime/` documenting the Docker-specific entrypoint and shared-memory override behavior.

## Impact

- **Code**: `Sources/ErrandDesktop/Container/ContainerEngine.swift` (command override for playwright), `ContainerRuntime.swift` (add shmSize to ContainerConfig), `DockerRuntime.swift` (pass ShmSize in HostConfig)
- **Resource usage**: ~100-150MB more memory per Playwright container, plus 2GB shared memory allocation
- **No protocol changes**: The Playwright MCP server interface and port remain identical
