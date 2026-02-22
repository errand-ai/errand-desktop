## Context

The upstream Errand project renamed its Docker image from `ghcr.io/errand-ai/errand-backend` to `ghcr.io/errand-ai/errand`. The backend, worker, and migrate containers all share this single image. ErrandDesktop hardcodes the old image name in three source files.

## Goals / Non-Goals

**Goals:**
- Update all image references from `errand-ai/errand-backend` to `errand-ai/errand`
- Update the main spec that references the old image name

**Non-Goals:**
- Config migration for users with existing `config.json` (the tag is stored, not the full image path)
- Renaming `contentManagerImageTag` config property (that's a separate concern)

## Decisions

**Decision: Simple string replacement, no abstraction**
The image path is only referenced in 3 source files. A find-and-replace is sufficient — no need to extract image names into constants or config.

**Decision: Update spec in-place**
The `container-commands` spec references "errand-backend image". This will be updated via a delta spec to keep the spec accurate.

## Risks / Trade-offs

- [Risk] Old image tags may not exist on the new image name → Users may need to re-select a tag. Mitigation: The tag list is fetched dynamically from GHCR.
