## REMOVED Requirements

### Requirement: Provider type detection via HTTP probing

**Reason**: Probing moves to the errand server, which already implements the identical algorithm and owns the provider registry. The app consumes the result rather than producing it.

### Requirement: Detection includes authorization header

**Reason**: The app no longer issues probe requests.

### Requirement: Detection timeout

**Reason**: The app no longer issues probe requests; timeout behaviour is the server's concern.

### Requirement: Detection skipped for local LiteLLM

**Reason**: The app no longer decides when to probe. A locally deployed LiteLLM is registered with the server like any other provider and classified by the server.

## ADDED Requirements

### Requirement: Provider configuration is delegated to the errand server

The app SHALL NOT probe LLM provider endpoints itself. Creating, updating, listing and classifying providers, and listing their models, SHALL be performed by calling the errand server's provider API. The app SHALL supply the API key when creating or updating a provider, and SHALL NOT expect the server to return it.

#### Scenario: Provider created through the server

- **WHEN** the user supplies a provider and its API key
- **THEN** the app sends them to the errand server
- **AND** the provider type recorded is the one the server reports

#### Scenario: No direct probing

- **WHEN** the app needs a provider's type or model list
- **THEN** it requests them from the errand server
- **AND** issues no request directly to the provider endpoint

#### Scenario: API key is not expected back

- **WHEN** the app reads provider data from the server
- **THEN** it does not rely on an API key being present in the response

### Requirement: The app supplies the host gateway address to the server

The app SHALL pass the address by which containers reach the host to the errand container as `HOST_GATEWAY_ADDRESS`, using the value it already resolves for the active container runtime. This allows server-side detection of AI runtimes on the host to record an address valid from inside every container.

#### Scenario: Docker runtime

- **WHEN** the errand container is started under the Docker runtime
- **THEN** `HOST_GATEWAY_ADDRESS` is set to the Docker host gateway name

#### Scenario: Apple containerization runtime

- **WHEN** the errand container is started under the Apple containerization runtime
- **THEN** `HOST_GATEWAY_ADDRESS` is set to that runtime's host gateway address

### Requirement: Core services start before provider configuration

The app SHALL start the services the errand server requires, and the errand server itself, before any step that configures LLM providers. A step that depends on the server SHALL NOT be presented until the server is reachable, and SHALL surface a clear failure with access to logs when it does not become reachable.

#### Scenario: Server available before configuration

- **WHEN** the user reaches a step that configures providers
- **THEN** the errand server is running and reachable

#### Scenario: Server fails to start

- **WHEN** the errand server does not become reachable
- **THEN** the app reports the failure with access to the service logs
- **AND** does not present a provider configuration step that cannot function

## MODIFIED Requirements

### Requirement: Detection results persisted

The provider type reported by the errand server SHALL be displayed without the app re-deriving it. The app MAY retain the last known provider base URL and type as a cache used solely to restart services while the server is unavailable; that cache SHALL NOT be treated as authoritative and SHALL be refreshed whenever the server responds.

#### Scenario: Detection result saved to config

- **WHEN** the errand server reports a provider type
- **THEN** the app records it as last-known state for service restart purposes

#### Scenario: Detection not re-run on app restart

- **WHEN** the app starts and the errand server is reachable
- **THEN** provider type and model information are read from the server rather than re-derived locally

### Requirement: Re-detection on URL or API key change

When the user changes a provider's base URL or API key, the app SHALL send the change to the errand server and display the provider type the server reports as a result. The app SHALL NOT perform its own probe.

#### Scenario: URL changed triggers re-detection

- **WHEN** the user modifies a provider base URL
- **THEN** the app updates the provider on the errand server
- **AND** displays the provider type the server reports

#### Scenario: API key changed triggers re-detection

- **WHEN** the user modifies a provider API key
- **THEN** the app updates the provider on the errand server
- **AND** displays the provider type the server reports
