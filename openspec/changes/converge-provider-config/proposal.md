## Why

errand-desktop and errand-server both implement LLM provider detection, and they implement it identically: probe `/model/info`, fall back to `/models`, classify as `litellm`, `openai_compatible` or `unknown`, with a 10-second timeout and an `Authorization` header. Desktop's `provider-detection` spec and errand's `probe_provider_type()` are the same algorithm maintained twice.

The duplication exists for a real reason — desktop launches the Hindsight container, so it needs the provider's type and model list to build that container's environment before starting it. But errand-server already owns this entire data model:

```
GET    /api/llm/providers
POST   /api/llm/providers                      probes on create
PUT    /api/llm/providers/{id}                 re-probes on URL change
DELETE /api/llm/providers/{id}
PUT    /api/llm/providers/{id}/default
GET    /api/llm/providers/{id}/models?mode=    already mode-filtered
```

Compose users configure providers through exactly these endpoints via errand's own settings UI. Desktop reimplemented that flow in Swift, and now maintains a second copy of the truth in `AppConfig`.

### Why this is safe to move

The obstacle looks like secrets, and turns out not to be. errand deliberately never returns a decrypted API key — provider serialisation masks it, and decryption happens only for errand's own outbound calls. An endpoint handing desktop a plaintext key would be a new exposure path, and this change does not add one.

It does not need to. Desktop already holds the key: the user typed it into the wizard and it lives in `AppConfig.llmProviderAPIKey`. So the key never round-trips. Everything crossing the API is non-secret:

```
 desktop                                  errand-server
 user types key ──POST provider─────────▶ encrypt, probe, classify
 model list     ◀──GET .../models?mode=── (non-secret)
      │
      └─ starts Hindsight with base URL, provider type and model from errand,
         and the API key from its own storage
```

### Two things that fall out of the errand-side work

`bundle-hindsight-runtime` runs embeddings in-process via ONNX. There is no longer an embedding model to choose, which removes an entire wizard concern rather than relocating it.

`local-ai-provider-detection` moves detection to the server and stores a base URL that is valid *from inside a container* — which is exactly what Hindsight needs, since Hindsight is also a container. Centralising detection therefore fixes the vantage-point problem for Hindsight for free, provided desktop tells errand which gateway address to use. Desktop already computes that value as `hostGatewayIP`.

## What Changes

- Desktop stops probing providers itself. Provider creation, type classification and model listing all go through the errand server.
- Desktop injects `HOST_GATEWAY_ADDRESS` into the errand container from its existing `hostGatewayIP`, so server-side detection works under both Docker and Apple Containerization.
- The startup graph gains an edge: errand starts before Hindsight, so the wizard's AI step can talk to it.
- The embedding-model selector is removed; the memory service no longer takes embedding configuration.
- `AppConfig` stops storing provider base URL and detected type as sources of truth, keeping the API key it alone holds, plus a last-known cache used only to restart services when the server is unavailable.
- The LiteLLM choice stops being the default and becomes an advanced option, alongside choosing a catalogued provider or adopting a detected local runtime.

## Capabilities

### Modified Capabilities

- `provider-detection` — probing is delegated; desktop consumes results instead of producing them.
- `setup-wizard-litellm-flow` — LiteLLM is no longer the default path.
- `setup-wizard-hindsight-flow` — model selection served by errand; embedding selection removed.
- `hindsight-service` — environment derived from errand's provider data plus desktop's own key.

## Non-goals

- Moving Hindsight's container lifecycle to errand. Desktop keeps starting, stopping and health-checking services; only configuration truth moves. errand's container runtime is built for ephemeral task containers, and compose and Kubernetes own that lifecycle differently — an errand-managed Hindsight would be a fourth model, not a unification.
- Removing LiteLLM support or the scoped service keys. Both keep working; they become advanced.
- Any change to how memory is used by the agent.
