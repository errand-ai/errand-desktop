## ADDED Requirements

### Requirement: Playwright MCP container service

ErrandDesktop SHALL manage a `playwright` container service using the `mcr.microsoft.com/playwright/mcp:latest` image, deployed as an always-on service with no config toggle. The container SHALL run non-headless under Xvfb so Chromium has a real X display, with shared-memory sized to support Chromium.

#### Scenario: Playwright starts with the stack
- **WHEN** the app starts all services
- **THEN** the `playwright` service is included in the startup sequence
- **AND** its container image is pulled (if not cached) and the entrypoint launches Xvfb on `:99` (1920x1080x24), waits for the X11 socket at `/tmp/.X11-unix/X99` to appear, then exec's `node /app/cli.js --browser chromium --no-sandbox --isolated --port 3000 --host 0.0.0.0 --allowed-hosts '*'` with `DISPLAY=:99`
- **AND** the container is configured with `shm_size` of 2 GiB to avoid Chromium crashes on `/dev/shm` exhaustion

#### Scenario: Playwright starts in the first wave
- **WHEN** the service dependency graph is evaluated
- **THEN** `playwright` has an empty dependency array and starts in the first wave alongside Postgres and Valkey

#### Scenario: Backend waits for Playwright
- **WHEN** the service dependency graph is evaluated
- **THEN** the `backend` service depends on `playwright` so that `PLAYWRIGHT_MCP_URL` points to a healthy listener by the time the backend container is created

### Requirement: Playwright isolated mode

The Playwright container SHALL run with the `--isolated` flag to ensure each Streamable HTTP session gets its own BrowserContext, preventing conflicts between concurrent task-runners.

#### Scenario: Concurrent task-runners use Playwright
- **WHEN** two task-runners connect to Playwright simultaneously
- **THEN** each gets an isolated browser context with separate cookies, localStorage, and navigation state

### Requirement: Playwright health check

The app SHALL health-check the Playwright container via a TCP probe on port 3000. The Playwright MCP server uses Streamable HTTP rather than a plain `/health` endpoint, so a TCP-accept check is sufficient to confirm the listener is up.

#### Scenario: Healthy Playwright
- **WHEN** the `playwright` container is running and accepts TCP connections on port 3000
- **THEN** the service status is `running`

#### Scenario: Unhealthy Playwright
- **WHEN** the `playwright` container does not accept TCP connections on port 3000 within the timeout
- **THEN** the service status is `error`

### Requirement: Playwright URL injection

When the Playwright service is running, its URL SHALL be injected as `PLAYWRIGHT_MCP_URL` into the backend container env vars.

#### Scenario: Playwright running
- **WHEN** the `playwright` container is running at IP `192.168.64.X`
- **THEN** `PLAYWRIGHT_MCP_URL=http://192.168.64.X:3000/mcp` is injected into the backend container env vars

#### Scenario: Playwright visible in service list
- **WHEN** the app is running
- **THEN** the Playwright service appears in the menu bar service list with display name "Playwright"
