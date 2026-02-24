## 1. AppConfig Updates

- [x] 1.1 Remove `litellmEnabled`, `oidcDiscoveryURL`, `oidcClientID`, `oidcClientSecret` from `AppConfig`
- [x] 1.2 Add `hindsightPort: Int = 8081`, `hindsightLLMModel: String = ""`, `hindsightEmbeddingModel: String = ""` to `AppConfig`

## 2. Startup Order

- [x] 2.1 Update `serviceStartupOrder` in `ServiceInfo.swift` to `[["postgres", "valkey"], ["migrate", "litellm", "hindsight"], ["backend"], ["worker"]]`
- [x] 2.2 Remove the dynamic LiteLLM insertion block in `ContainerEngine.startAll` (the `if config.litellmEnabled && ...` order patch)
- [x] 2.3 Remove the dynamic LiteLLM append in `ContainerEngine.stopAll` and use the static order (reversed) instead

## 3. LiteLLM Container Integration

- [x] 3.1 Update `imageSpecs` in `ContainerEngine` to use `ghcr.io/berriai/litellm-database:main-v1.81.3-stable` for the `litellm` case
- [x] 3.2 Add `LITELLM_MASTER_KEY` generation: create a new Keychain account `"litellm-master-key"` in `KeychainManager.getOrCreate` and pass it to `ContainerEngine`
- [x] 3.3 Update `buildEnv` for `"litellm"`: add `DATABASE_URL` (postgres IP) and `LITELLM_MASTER_KEY`
- [x] 3.4 Update `buildEnv` for `"backend"`: always set `OPENAI_BASE_URL` from litellm IP (remove the `litellmEnabled` guard); set `OPENAI_API_KEY` to the litellm master key
- [x] 3.5 Update `buildEnv` for `"worker"`: always set `OPENAI_BASE_URL` from litellm IP; set `OPENAI_API_KEY` to the litellm master key

## 4. Hindsight Container Integration

- [x] 4.1 Add `"hindsight"` to `imageSpecs` returning `"ghcr.io/vectorize-io/hindsight:latest-slim"`
- [x] 4.2 Add `"hindsight"` case to `buildEnv`: set `DATABASE_URL`, `LITELLM_BASE_URL`, `HINDSIGHT_LLM_MODEL`, `HINDSIGHT_EMBEDDING_MODEL`
- [x] 4.3 Add `"hindsight"` case to `buildMountObjects`: virtiofs share from `storageManager.dataPath(for: "hindsight")` to `/data`
- [x] 4.4 Add `"hindsight"` case to `checkHealth` in `ContainerEngine`: HTTP GET `/health` at container IP on port 8080
- [x] 4.5 Add `"hindsight"` case to `checkHealth` in `HealthChecker` (if present separately)
- [x] 4.6 Add `"hindsight"` to `buildEnv` for `"backend"`: set `HINDSIGHT_BASE_URL` = `http://<hindsightIP>:8080`
- [x] 4.7 Add `"hindsight"` to `buildEnv` for `"worker"`: set `HINDSIGHT_BASE_URL` = `http://<hindsightIP>:8080`

## 5. Storage

- [x] 5.1 Add `"hindsight"` to the `subdirs` array in `StorageManager.ensureDataDirectories`

## 6. AppState Updates

- [x] 6.1 Remove the `if config.litellmEnabled { addLiteLLMService() }` call and the `addLiteLLMService()` method — add litellm and hindsight to the initial `services` array directly alongside the other services
- [x] 6.2 Remove the `if config.litellmEnabled { try await liteLLMManager?.start(...) }` block in `startAll` — LiteLLM is now started by `ContainerEngine`
- [x] 6.3 Remove the `try? await liteLLMManager?.stop()` call from `stopAll` — LiteLLM is now stopped by `ContainerEngine`
- [x] 6.4 Add the `LITELLM_MASTER_KEY` Keychain fetch to `initialize()` and pass it to `ContainerEngine` (alongside the existing credential encryption key)

## 7. Settings UI

- [x] 7.1 Remove `OIDCTab` struct from `SettingsView.swift`
- [x] 7.2 Add `MemoryTab` struct to `SettingsView.swift` with `TextField` for `hindsightLLMModel` (labelled "LLM Model") and `TextField` for `hindsightEmbeddingModel` (labelled "Embedding Model"), plus a Save button
- [x] 7.3 Replace the OIDC tab entry in `SettingsView.body` with a Memory tab entry (label "Memory", system image `"brain.head.profile"`)
- [x] 7.4 Remove the "Enable LiteLLM Proxy" toggle and its surrounding section from `GeneralTab`
- [x] 7.5 Remove the LiteLLM port field from `PortsTab` in `SettingsView` (or keep it — decide based on whether the port remains configurable)

## 8. Setup Assistant

- [x] 8.1 Remove the LiteLLM enable toggle step from `SetupAssistantView` (the `litellmStep` view and its case in the tab sequence)

## 9. Log Viewer

- [x] 9.1 Add `"hindsight"` colour entry to the log viewer colour map in `LogViewerView.swift`
