## Why

The upstream Errand project has renamed its Docker image from `ghcr.io/errand-ai/errand-backend` to `ghcr.io/errand-ai/errand`. All references in ErrandDesktop must be updated to match.

## What Changes

- **BREAKING**: Update all OCI image references from `errand-ai/errand-backend` to `errand-ai/errand`
- Update `ContainerEngine` image mapping for backend, worker, and migrate services
- Update `SettingsView` default image value
- Update `GHCRTagFetcher` doc comment example

## Capabilities

### New Capabilities

_None_

### Modified Capabilities

- `container-commands`: The migrate container spec references "errand-backend image" — update to "errand image"

## Impact

- **Source files**: `ContainerEngine.swift`, `SettingsView.swift`, `GHCRTagFetcher.swift`
- **Specs**: `openspec/specs/container-commands/spec.md` references old image name
- **User-facing**: Users with existing `config.json` storing the old image name will need to update or the app needs to handle migration
