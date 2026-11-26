# Digital Archive Metadata PoC

Local proof of concept for archival metadata changes sent as JSON through SQS, processed by a Lambda function, and stored in PostgreSQL. Docker Compose runs [Floci](https://github.com/hectorvent/floci) to provide local AWS-shaped SQS, Lambda, and RDS behavior.

```text
JSON event -> SQS -> Lambda -> PostgreSQL
```

## Project structure

| Path                                  | Purpose                                                        |
| ------------------------------------- | -------------------------------------------------------------- |
| `compose.yaml`                        | Local Floci container with Lambda hot-reload.                  |
| `schema.sql`                          | DDL-only PostgreSQL schema (`archive`, `history`, views).      |
| `events/`                             | Curated fixtures: `seed/`, `lifecycle/`, `bulk/`, `demos/`.    |
| `lambda/handler.py`                   | Metadata change processor (SCD2, audit, batch, `entity_keys`). |
| `lambda/expiry_checker.py`            | Manual sensitivity expiry checker.                             |
| `scripts/demo-initial-state.sh`       | Build infra only (no data).                                    |
| `scripts/reset-demo-data.sh`          | Fast data reset: truncate data, reseed base data.              |
| `scripts/demo-lifecycle.sh`           | Lifecycle demo (resets data by default).                       |
| `scripts/demo-batching.sh`            | Batch/multi-id demo (resets data by default).                  |
| `scripts/demo-expiry.sh`              | Expiry demo (resets data by default).                          |
| `scripts/demo-sqs.sh`                 | SQS async demo (resets data by default).                       |
| `scripts/send-events.sh`              | Generic event sender.                                          |
| `scripts/check-sensitivity-expiry.sh` | Manual expiry checker.                                         |

## Data model

### Entity model

```mermaid
erDiagram
  "consignment" ||..o{ "file" : "consignment_id -> consignment_id"
  "representation" ||..o{ "file" : "representation_id -> representation_id"
  "series" ||..o{ "record" : "series_id -> series_id"
  "version" ||..o{ "representation" : "version_id -> version_id"
  "version_description" |o..o{ "sensitivity" : "version_description_id -> version_description_id"
  "version" |o..o{ "sensitivity" : "version_id -> version_id"
  "version_path" |o..o{ "sensitivity" : "version_path_id -> version_path_id"
  "version_title" |o..o{ "sensitivity" : "version_title_id -> version_title_id"
  "department" ||..o{ "series" : "department_id -> department_id"
  "record" ||..o{ "version" : "record_id -> record_id"
  "version" ||..o{ "version_description" : "version_id -> version_id"
  "version" ||..o{ "version_path" : "version_id -> version_id"
  "version" ||..o{ "version_title" : "version_id -> version_id"

  "consignment" {
    uuid consignment_id PK
    text consignment_reference UK "NOT NULL"
    timestamptz received_at "NOT NULL"
    text source_organisation
    text notes
    timestamptz updated_at "NOT NULL"
  }
  "department" {
    uuid department_id PK
    text department_code UK "NOT NULL"
    text name "NOT NULL"
    timestamptz updated_at "NOT NULL"
  }
  "file" {
    uuid file_id PK
    uuid representation_id FK "NOT NULL -> archive.representation.representation_id"
    uuid consignment_id FK "NOT NULL -> archive.consignment.consignment_id"
    text file_name "NOT NULL"
    text relative_path "NOT NULL"
    timestamptz updated_at "NOT NULL"
  }
  "metadata_change_event" {
    uuid metadata_change_event_id PK
    uuid event_group_id "NOT NULL"
    uuid source_event_id UK "NOT NULL"
    text entity_type "NOT NULL"
    uuid entity_id
    jsonb entity_key "NOT NULL"
    char(1) change_type "NOT NULL"
    text outcome "NOT NULL"
    text processing_status "NOT NULL"
    jsonb changes "NOT NULL"
    jsonb raw_change_payload "NOT NULL"
    timestamptz changed_at "NOT NULL"
    timestamptz received_at "NOT NULL"
    timestamptz processed_at
    text changed_by_id "NOT NULL"
    text changed_by_name
    text change_reason "NOT NULL"
    text source_system "NOT NULL"
    text error_message
  }
  "record" {
    uuid record_id PK
    uuid series_id FK "NOT NULL -> archive.series.series_id"
    text record_reference "NOT NULL"
    timestamptz updated_at "NOT NULL"
  }
  "representation" {
    uuid representation_id PK
    uuid version_id FK "NOT NULL -> archive.version.version_id"
    text representation_code "NOT NULL"
    text representation_type "NOT NULL"
    timestamptz updated_at "NOT NULL"
  }
  "sensitivity" {
    uuid sensitivity_id PK
    uuid version_id FK "-> archive.version.version_id"
    uuid version_title_id FK "-> archive.version_title.version_title_id"
    uuid version_description_id FK "-> archive.version_description.version_description_id"
    uuid version_path_id FK "-> archive.version_path.version_path_id"
    text sensitivity_type "NOT NULL"
    text sensitivity_type_code
    text sensitivity_status "NOT NULL"
    date sensitivity_start
    text sensitivity_period
    text sensitivity_rule "NOT NULL"
    date sensitivity_end
    date review_date
    text review_outcome
    text schedule_reference
    text archivist_note
    timestamptz updated_at "NOT NULL"
  }
  "series" {
    uuid series_id PK
    uuid department_id FK "NOT NULL -> archive.department.department_id"
    text series_code "NOT NULL"
    text name "NOT NULL"
    timestamptz updated_at "NOT NULL"
  }
  "version" {
    uuid version_id PK
    uuid record_id FK "NOT NULL -> archive.record.record_id"
    text version_code "NOT NULL"
    text default_title_code
    text default_description_code
    text default_path_code
    timestamptz updated_at "NOT NULL"
  }
  "version_description" {
    uuid version_description_id PK
    uuid version_id FK "NOT NULL -> archive.version.version_id"
    text description_code "NOT NULL"
    text description_text "NOT NULL"
    text language_code "NOT NULL"
    text variant_code "NOT NULL"
    timestamptz updated_at "NOT NULL"
  }
  "version_path" {
    uuid version_path_id PK
    uuid version_id FK "NOT NULL -> archive.version.version_id"
    text path_code "NOT NULL"
    text path_value "NOT NULL"
    text path_type "NOT NULL"
    timestamptz updated_at "NOT NULL"
  }
  "version_title" {
    uuid version_title_id PK
    uuid version_id FK "NOT NULL -> archive.version.version_id"
    text title_code "NOT NULL"
    text title_text "NOT NULL"
    text language_code "NOT NULL"
    text variant_code "NOT NULL"
    timestamptz updated_at "NOT NULL"
  }
```

```text
Department -> Series -> Record -> Version -> Representation -> File
Consignment -> File
```

Domain tables (current state): `department`, `series`, `record`, `version`, `version_title`, `version_description`, `version_path`, `representation`, `consignment`, `file`, `sensitivity`. Processed event records are stored in `archive.metadata_change_event`.

Titles, descriptions, and paths have UUID primary keys and business keys per version:

```text
UNIQUE (version_id, title_code)
UNIQUE (version_id, description_code)
UNIQUE (version_id, path_code)
```

This supports variants such as `en_1`, `cy_1`, `en_r_1`, and `cy_r_1`. A version stores default codes so the preferred title, description, and path can be resolved quickly.

### Schemas and history

- **`archive`**: current operational tables with normal foreign keys.
- **`history`**: SCD Type 2 history tables for domain entities (`department`, `series`, `record`, `version`, `version_title`, `version_description`, `version_path`, `representation`, `consignment`, `file`, `sensitivity`).

Each history row includes:

```text
valid_from, valid_to, is_current
changed_at, changed_by_id, changed_by_name, change_reason, source_event_id
```

An update is applied in one transaction: the current `archive` row is updated, the previous current `history` row is closed, and a new current `history` row is inserted.

### Sensitivity

`sensitivity` targets exactly one of: `version_id`, `version_title_id`, `version_description_id`, or `version_path_id` (enforced by a check constraint). Stored fields are source of truth; exposure is derived (not writable).

Key fields include:

- `sensitivity_type` / `sensitivity_type_code` (`FOIA`, `AUR`, `Retained`, `not crown copyright`, `commercial`, `do not publish`)
- `sensitivity_status` (`active`, `internal_review`, `advisory_council_review`, `superceeded`, `cancelled`, `expired`) - restricting: `active|internal_review|advisory_council_review`; non-restricting: `expired|cancelled|superceeded`
- `sensitivity_start`, `sensitivity_period`, `sensitivity_rule` (`JAN_AFTER_PERIOD`, `EXACT_PERIOD`, `MANUAL`), `sensitivity_end`
- review fields (`review_date`, `review_outcome`) - while under `internal_review`/`advisory_council_review`, keep `null`; set on next outcome status (`active`/`cancelled`)
- `schedule_reference`, `archivist_note`

For non-`MANUAL` rules, Lambda computes `sensitivity_end` from start+period+rule (if derived date is exactly `YYYY-01-01`, `JAN_AFTER_PERIOD` moves to `YYYY+1-01-01`). Events must not supply `sensitivity_end` for automatic rules. For `MANUAL` (or changing to `MANUAL`), events must explicitly supply `sensitivity_end` (`date` or `null`).

Derived exposure is shown only in `archive.current_version_display.sensitivity_exposure` (version scope, existing `version/title/description/path` targets only): `OPEN` = no restricting sensitivities; `PARTIALLY_OPEN` = restricting + >=1 unrestricted sibling target; `CLOSED` = restricting and no unrestricted sibling target. `do not publish` is restricting when active/internal_review/advisory_council_review (derived `CLOSED` by current PoC decision).

Manual expiry checker (no cron): `./scripts/check-sensitivity-expiry.sh` finds active sensitivities past `sensitivity_end` and emits deterministic idempotent events setting `sensitivity_status='expired'`. See `SENSITIVITY_LIFECYCLE.md` and `events/`.

### Views

Defined in `schema.sql`:

- `archive.current_version_display`: one readable row per version with resolved default title/description/path and derived `sensitivity_exposure` (`OPEN|PARTIALLY_OPEN|CLOSED`).
- `archive.current_active_sensitivity`: sensitivity rows currently considered active for filtering (`sensitivity_status` in `active`, `internal_review`, or `advisory_council_review`).

Other current-state inspection is done directly against `archive.*` tables.

### Audit

Every accepted event is written to `archive.metadata_change_event`, including entity key/type/ID, change type, outcome, processing status, changes, raw JSON payload, actor/reason/source, timestamps, and `event_group_id`. Lambda returns `event_group_id` for quick audit lookup; `source_event_id` is Lambda-generated, deterministic, and unique for idempotent processing.

## Infrastructure

```mermaid
flowchart LR
  Sender[Demo script or application] -->|JSON change event| SQS[Floci SQS<br/>metadata-change-events]
  SQS -->|event-source mapping| Lambda[Floci Lambda<br/>metadata-change-processor]
  Lambda -->|transactional update + audit| RDS[Floci RDS PostgreSQL]
  RDS --> Archive[archive schema<br/>current operational tables]
  RDS --> History[history schema<br/>SCD Type 2 tables]
  Lambda --> Audit[archive.metadata_change_event]
  SQS -. failed records retry .-> DLQ[Floci SQS DLQ<br/>metadata-change-dlq]
  Floci[Docker Compose<br/>Floci emulator] --- SQS
  Floci --- Lambda
  Floci --- RDS
```

- The main queue (`metadata-change-events`) receives change messages.
- An enabled SQS-to-Lambda event-source mapping invokes `metadata-change-processor`.
- Lambda applies changes transactionally: it updates `archive` current rows, closes/inserts `history` (SCD Type 2) rows, and records the processed event in `archive.metadata_change_event`.
- Failed records can be retried and are eventually sent to the DLQ (`metadata-change-dlq`) per the queue redrive policy.
- Lambda hot-reload is enabled in `compose.yaml`, so edits under `lambda/` are picked up on invocation without redeploying the function package.

## Local run

### Prerequisites (WSL)

Tested workflow assumes WSL2 (e.g. Ubuntu) with the following installed:

- **Docker** with Compose v2 (`docker compose`) and access to the Docker daemon. Docker Desktop with WSL integration, or Docker Engine running inside WSL, both work. Your user must be able to run Docker commands.
- **AWS CLI v2** (`aws`) for driving Floci’s AWS-compatible APIs.
- **PostgreSQL client** (`psql`) for applying `schema.sql` and inspection queries.
- **jq** for working with JSON events in scripts.
- **Python 3** with `pip` (`python3`, `python3 -m pip`) to install Lambda dependencies into `lambda/vendor`.
- **curl** and **bash** (used by verification/demo scripts).

Example (Ubuntu/Debian, adjust to your environment):

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 awscli postgresql-client jq python3 python3-pip curl
sudo usermod -aG docker "$USER"
# restart your WSL session if you changed docker group membership
```

> Scripts use dummy local credentials from `.env.example`; no real AWS account or credentials are required.

### Environment

`.env.example` defines the local endpoint, dummy AWS credentials, and RDS settings used by the scripts:

```bash
set -a && . ./.env.example && set +a
```

The demo scripts source this file automatically. Key values:

| Variable                                                           | Purpose                                                   |
| ------------------------------------------------------------------ | --------------------------------------------------------- |
| `AWS_ENDPOINT_URL`                                                 | Floci endpoint (`http://localhost:4566`)                  |
| `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Dummy/local AWS config for CLI                            |
| `LOCAL_RDS_*`                                                      | Local RDS instance/database/user/password used by scripts |

### 1. Build infrastructure (once)

```bash
./scripts/demo-initial-state.sh
```

Resets Floci/RDS, applies `schema.sql`, creates Lambdas/SQS mapping. No data seeded.

### 2. Run curated demos

Each demo resets DB data by default (truncate data + seed base data), no container rebuild, and is self-explanatory: prints exact JSON, invokes/sends it, shows focused DB tables, pauses between stages.

```bash
./scripts/demo-lifecycle.sh   # sensitivity lifecycle: review/ACR/release/AUR+DNP, exposure, SCD2
./scripts/demo-batching.sh    # batch wrapper + entity_keys same-change, audit/row evidence
./scripts/demo-expiry.sh      # past-end active sensitivity, manual expiry checker, idempotent rerun
./scripts/demo-sqs.sh         # async SQS -> Lambda mapping, queue attrs, resulting DB state
```

Add `--no-reset` to keep current DB state. `./scripts/reset-demo-data.sh` does data-only reset. `./scripts/send-events.sh <file> [lambda|sqs]` for ad-hoc files.

### Event payload notes

- Caller does not supply `changed_at`; Lambda uses a single DB `clock_timestamp()` per event for current/history/audit.
- `entity_type` is required with `entity_key`/`entity_keys`. Do not send `event_id`; Lambda returns `event_group_id` for audit lookup and generates deterministic `source_event_id` values for idempotency.
- Bulk: `{"events":[...]}` runs in one invocation/connection with per-event commit and one `event_group_id`. `entity_keys:[...]` expands one logical change to deterministic per-target events (same `event_group_id`, different `source_event_id`). SQS `Records` contract unchanged.

### Database explorer

Connect with any PostgreSQL client:

| Field    | Value                                                              |
| -------- | ------------------------------------------------------------------ |
| Driver   | PostgreSQL                                                         |
| Host     | `localhost`                                                        |
| Port     | `7001` (or the endpoint port reported for `LOCAL_RDS_INSTANCE_ID`) |
| Database | `metadata_history`                                                 |
| Username | `metadata_admin`                                                   |
| Password | `local-poc-password`                                               |

Useful queries:

```sql
-- Stakeholder views
SELECT * FROM archive.current_version_display;
SELECT * FROM archive.current_active_sensitivity;

-- Audit trail
SELECT * FROM archive.metadata_change_event ORDER BY processed_at;

-- SCD Type 2 history examples
SELECT version_id, default_title_code, valid_from, valid_to, is_current
FROM history.version
ORDER BY valid_from;

SELECT version_title_id, title_code, title_text, valid_from, valid_to, is_current
FROM history.version_title
WHERE version_title_id = '10000000-0000-4000-8000-000000000013'
ORDER BY valid_from;

SELECT sensitivity_id, sensitivity_status, sensitivity_end, valid_from, valid_to, is_current
FROM history.sensitivity
ORDER BY valid_from;
```
