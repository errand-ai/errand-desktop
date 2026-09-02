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

---

### Requirement: Existing databases are migrated off the legacy password
On an install whose data directory predates generated credentials, `POSTGRES_PASSWORD` is ignored because `PGDATA` already exists, so the database still uses the shared default `postgres`. Once Postgres is healthy and before any dependent service is started, the app SHALL determine which password the database actually accepts and, when it is the legacy one, rotate it to the generated password. The generated password SHALL be recorded before the database is altered, so that an interrupted rotation is recoverable.

#### Scenario: Stored password already works
- **WHEN** Postgres becomes healthy and the stored password authenticates
- **THEN** the app uses it unchanged and performs no rotation

#### Scenario: Upgraded install is rotated off the legacy password
- **WHEN** Postgres becomes healthy, the stored password does not authenticate, and the legacy password `postgres` does
- **THEN** the app records a freshly generated password, alters the database to use it, and hands that password to dependent services

#### Scenario: Rotation is interrupted
- **WHEN** the generated password has been recorded but altering the database did not complete
- **THEN** the database keeps the legacy password for the current run, and the next launch detects this and retries the rotation

#### Scenario: Neither password authenticates
- **WHEN** neither the stored nor the legacy password authenticates
- **THEN** the app reports that it cannot authenticate to Postgres rather than starting dependent services with a password known to be wrong
