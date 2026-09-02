## 1. Prerequisites

This change builds on two errand-server changes. Verify against a built errand image, not a branch.

- [ ] 1.1 Confirm `bundle-hindsight-runtime` has merged and the memory runtime image runs embeddings in-process
- [ ] 1.2 Confirm `local-ai-provider-detection` has merged, providing the provider catalog, the local-AI scan and `HOST_GATEWAY_ADDRESS`
- [ ] 1.3 Create branch `converge-provider-config` from an up-to-date `main`

## 2. Settle the wizard failure path

First, because it is the largest unknown and it shapes every step that follows.

- [ ] 2.1 Decide what the wizard shows while core services start, and what the user can do when they do not become healthy
- [ ] 2.2 Decide whether the Settings LLM tab keeps editing or becomes a read-through to the server's provider settings
- [ ] 2.3 Replace both open questions in `design.md` with the decisions

## 3. Startup ordering

- [ ] 3.1 Add a dependency edge so the errand server starts and becomes healthy before the hindsight container is created
- [ ] 3.2 Pass `HOST_GATEWAY_ADDRESS` to the errand container from the value already resolved for the active runtime
- [ ] 3.3 Verify the ordering under both the Docker and Apple containerization runtimes
- [ ] 3.4 Verify that server-side local-AI detection, run from inside the errand container, finds a runtime listening on the host

## 4. Delegate provider configuration

- [ ] 4.1 Write failing tests: creating a provider calls the errand server; no request is made directly to a provider endpoint; provider type displayed is the server's; the app does not depend on an API key coming back
- [ ] 4.2 Replace the local probing implementation with calls to the errand server's provider API
- [ ] 4.3 Route base URL and API key changes through the server and display the type it reports
- [ ] 4.4 Delete the local probing code and its tests once the replacements pass

## 5. Configuration ownership

- [ ] 5.1 Keep the provider API key in app storage; it is the one value the server will not return
- [ ] 5.2 Reduce stored base URL and provider type to an explicitly named restart cache, refreshed whenever the server responds
- [ ] 5.3 Write a failing test: restarting the memory service while the server is unreachable uses the cache and reports the configuration as possibly stale
- [ ] 5.4 Confirm no code path treats the cache as authoritative while the server is reachable

## 6. LLM configuration step

- [ ] 6.1 Write failing tests: LiteLLM is not selected by default; detected runtimes are offered; catalogued providers require only a key; the unlisted entry requires base URL and key
- [ ] 6.2 Present the three routes: adopt a detected runtime, choose from the catalog, or deploy LiteLLM as the advanced option
- [ ] 6.3 Create the chosen provider on the errand server with the supplied key
- [ ] 6.4 Mirror the same three routes in the Settings LLM tab

## 7. Agent Memory step

- [ ] 7.1 Write failing tests: a single chat-model selector populated from the server; direct entry when listing is unsupported or fails; the selector is disabled when memory is off; no embedding control is rendered anywhere
- [ ] 7.2 Replace the paired dropdowns with one chat-model selector sourced from the errand server
- [ ] 7.3 Remove the embedding-model selector from both the wizard and the Settings Memory tab
- [ ] 7.4 Remove embedding environment variables from the hindsight container environment

## 8. Hindsight environment

- [ ] 8.1 Write failing tests: the LLM base URL and model come from the server; the key comes from local storage or the scoped service key; no embeddings variables are set
- [ ] 8.2 Build the container environment from server-reported provider data plus the locally held key
- [ ] 8.3 Point the memory service at the shared database and its own schema
- [ ] 8.4 Verify memory works end to end: start services from cold, retain during a task, recall in a later one

## 9. Verify

- [ ] 9.1 Run the full desktop test suite
- [ ] 9.2 Complete a first-run setup from a clean state under the Docker runtime
- [ ] 9.3 Complete a first-run setup from a clean state under the Apple containerization runtime
- [ ] 9.4 Exercise the failure path decided in 2.1 by preventing the errand server from becoming healthy
- [ ] 9.5 Confirm an existing LiteLLM-based installation still works after upgrading

## 10. Archive

- [ ] 10.1 `openspec archive converge-provider-config -y` and commit the result in this PR

## Post-merge notes

- Once this lands, provider detection exists in exactly one place; a future provider type only needs adding to the errand server.
- The homebrew distribution work should be checked against the new startup ordering, since the wizard now depends on the errand server being reachable earlier than before.
