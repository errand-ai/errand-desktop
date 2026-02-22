## 1. Update source references

- [x] 1.1 Update `ContainerEngine.swift:694` — change `errand-ai/errand-backend` to `errand-ai/errand` in `imageSpecs()`
- [x] 1.2 Update `SettingsView.swift:112` — change `errand-ai/errand-backend` to `errand-ai/errand` in `fetchTags()`
- [x] 1.3 Update `GHCRTagFetcher.swift:8` — change doc comment example from `errand-ai/errand-backend` to `errand-ai/errand`

## 2. Update specs

- [x] 2.1 Update `openspec/specs/container-commands/spec.md` — change "errand-backend image" to "errand image" in migrate container scenario

## 3. Verify

- [x] 3.1 Run `swift build` to confirm compilation succeeds
