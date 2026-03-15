## 1. Keychain Storage

- [x] 1.1 Add `get` and `set` methods to `KeychainManager` for accounts `litellm-errand-key` and `litellm-hindsight-key` (or make existing helpers reusable for arbitrary accounts)
- [x] 1.2 Add a `delete` method to `KeychainManager` for removing a key by account name (needed for stale key cleanup)

## 2. Key Provisioning in ContainerEngine

- [x] 2.1 Add `errandServiceKey` and `hindsightServiceKey` stored properties to `ContainerEngine`
- [x] 2.2 Implement `provisionServiceKeys(litellmHost: String, litellmPort: Int)` method that: loads keys from Keychain, validates via `GET /key/info`, generates missing/stale keys via `POST /key/generate`, stores new keys in Keychain
- [x] 2.3 Add runtime-aware URL resolution in `provisionServiceKeys` — `localhost:{port}` for Docker, `{containerIP}:4000` for Apple Containerization
- [x] 2.4 Add fallback: if provisioning fails, set `errandServiceKey`/`hindsightServiceKey` to `litellmMasterKey` and log a warning

## 3. Env Var Injection

- [x] 3.1 Update `buildEnv` for `backend` case: use `errandServiceKey` instead of `litellmMasterKey` for `OPENAI_API_KEY`
- [x] 3.2 Update `buildEnv` for `worker` case: use `errandServiceKey` instead of `litellmMasterKey` for `OPENAI_API_KEY`
- [x] 3.3 Update `buildEnv` for `hindsight` case: use `hindsightServiceKey` instead of `litellmMasterKey` for `HINDSIGHT_API_LLM_API_KEY` and `HINDSIGHT_API_EMBEDDINGS_LITELLM_API_KEY`
- [x] 3.4 Verify `litellm` case still uses `litellmMasterKey` for `PROXY_MASTER_KEY` / `LITELLM_MASTER_KEY` (no change needed, just confirm)

## 4. Startup Integration

- [x] 4.1 In `ContainerEngine.startSingleService()`: after LiteLLM health check passes, call `provisionServiceKeys()` before returning
- [x] 4.2 In `AppState.startSetupServices()`: after LiteLLM is healthy, call `containerEngine.provisionServiceKeys()` before the method returns
- [x] 4.3 Verify that `fetchAvailableModels()` in AppState still uses the master key (no change needed, just confirm)

## 5. Testing

- [x] 5.1 Manual test: first run through setup wizard — verify keys generated, stored in Keychain, Hindsight model dropdown loads
- [x] 5.2 Manual test: restart app — verify keys loaded from Keychain, validated, reused (check debug log)
- [x] 5.3 Manual test: delete LiteLLM Postgres DB, restart — verify stale keys detected and regenerated
- [x] 5.4 Manual test: verify Backend/Worker/Hindsight containers receive service keys (not master key) via debug log or container inspect
