## Context

Desktop duplicates errand's provider detection because it needs provider type and model lists to build the Hindsight container's environment before starting it. This change removes the duplicate by making errand the single source of provider truth, while leaving container lifecycle where it is.

It depends on two errand changes: `bundle-hindsight-runtime` (which removes embedding configuration) and `local-ai-provider-detection` (which adds the scan operation, the provider catalog, and `HOST_GATEWAY_ADDRESS`). Neither is optional — implementing this first would mean building against endpoints that do not exist.

## Decisions

### D1 — The split is drawn at secrets, not at "all of it"

errand never returns a decrypted API key, and this change does not ask it to. Desktop supplies the key on provider creation and retains its own copy for injecting into Hindsight; errand returns only non-secret data. This keeps the credential model intact and is what makes the convergence achievable without weakening it.

### D2 — Desktop keeps lifecycle; errand owns configuration

The tempting larger move is to let errand manage the Hindsight container through its own container runtime. Rejected:

- It would apply only to desktop. Compose defines Hindsight as a compose service and Kubernetes as a Deployment, so an errand-managed Hindsight would be a fourth lifecycle model rather than a unification.
- errand's runtime is built for ephemeral task containers. A long-lived stateful service brings restart policy, upgrade, volume ownership and health semantics that do not exist there.
- Desktop's menu bar surfaces per-service health; it would lose visibility into a service it no longer starts.

The narrow waist stays where it is: errand owns configuration truth, desktop owns lifecycle and the secret.

### D3 — Bootstrap inversion is the real cost

Today the wizard collects AI configuration and then starts services. This reverses it:

```
 now:       [wizard: AI config] ──▶ start postgres, litellm, hindsight, errand
 proposed:  start postgres, valkey, errand ──▶ [wizard: AI config via errand]
                                          ──▶ start hindsight
```

This works because errand-server depends on neither Hindsight nor LiteLLM — memory configuration is optional and providers are database-driven, so errand boots with no configuration at all. Desktop's startup is already dependency-ordered with parallel resolution, so this is an edge in the graph rather than a rewrite.

The cost is UX: the wizard needs a phase where core services come up, and a failure there is now a wizard dead-end rather than a configuration error. That is the main thing this change has to get right.

### D4 — `AppConfig` keeps the key and a restart cache, not the truth

Once errand is authoritative, a stored base URL and detected type are a cache that can go stale. But desktop must still be able to restart Hindsight when errand is unavailable, so a last-known-good cache is kept explicitly as a cache: refreshed from errand whenever it responds, used only as a fallback, and never treated as authoritative for display.

`llmProviderAPIKey` stays, because it is the one value errand will not give back.

### D5 — Desktop supplies the gateway address

errand-server cannot derive whether it is under Docker or Apple Containerization. Desktop already resolves this as `hostGatewayIP` — `host.docker.internal` for Docker, the vmnet gateway for Apple — and passes it to errand as `HOST_GATEWAY_ADDRESS`. Server-side local-AI detection then probes and stores a URL that is valid from inside every container, including Hindsight's.

### D6 — No native probe is kept, even for a fast first-run splash

Showing "we found Ollama" before errand is up would be nicer. It is also exactly how the present duplication began. Detection results come from the server or are not shown.

## Risks

- **Wizard dead-end.** If errand fails to become healthy, the AI step has nothing to talk to. The wizard needs a real failure path with logs, not a spinner.
- **Cache divergence.** A restart cache that is silently used when the server is merely slow, rather than genuinely down, would reintroduce two sources of truth by the back door.
- **Cross-repo sequencing.** Building against endpoints that have not shipped. Mitigated by the dependency being explicit and by verifying against a built errand image rather than a branch.

## Open Questions

- What does the wizard display while core services start — and what is the recovery path when they do not? This is the largest remaining unknown and should be settled before the wizard work begins.
- Does the Settings LLM tab keep any editing at all, or become a read-through to errand's own provider settings? A read-through is less code but makes desktop's settings inconsistent with its other tabs.
