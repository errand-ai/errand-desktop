## ADDED Requirements

### Requirement: Postgres password is generated randomly and stored in Keychain
The app SHALL generate a random Postgres password at first run and store it in the Keychain under account `postgres-password`. On all subsequent starts the stored password SHALL be read from the Keychain. The hardcoded `postgres:postgres` credentials SHALL NOT be used.

#### Scenario: First run generates and stores a random password
- **WHEN** the app starts and no `postgres-password` entry exists in the Keychain
- **THEN** a random 32-character alphanumeric password is generated
- **THEN** the password is stored in the Keychain under service `sh.errand.ErrandDesktop`, account `postgres-password`
- **THEN** the Postgres container is started with `POSTGRES_PASSWORD` set to this generated password

#### Scenario: Subsequent runs read the stored password
- **WHEN** the app starts and a `postgres-password` entry exists in the Keychain
- **THEN** the stored password is read from the Keychain
- **THEN** the Postgres container is started with `POSTGRES_PASSWORD` set to the stored password
- **THEN** `DATABASE_URL` for Backend, Worker, and LiteLLM uses the same stored password

#### Scenario: Postgres container fails to start due to credential mismatch
- **WHEN** the Postgres container fails its health check and the Keychain password differs from the initialized disk password
- **THEN** the app logs an error indicating a possible credential mismatch and prompts the user to reset Postgres data
