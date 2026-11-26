# Sensitivity lifecycle (PoC)

This is the current PoC behavior. Stored fields are authoritative; exposure is derived in `archive.current_version_display.sensitivity_exposure` only.

## Rules

- **Statuses (stored):** `active`, `internal_review`, `advisory_council_review`, `superceeded`, `cancelled`, `expired`.
- **Restricting statuses:** `active`, `internal_review`, `advisory_council_review`.
- **Non-restricting statuses:** `expired`, `cancelled`, `superceeded`.
- **Derived exposure (version scope, existing targets only):** targets considered are existing `archive.version`, `archive.version_title`, `archive.version_description`, `archive.version_path` rows for the same version.
  - `OPEN`: no restricting sensitivity on any existing target in the version.
  - `PARTIALLY_OPEN`: at least one restricting sensitivity and at least one existing sibling target with no restricting sensitivity.
  - `CLOSED`: restricting sensitivity exists and no existing sibling target is unrestricted.
- **DO NOT PUBLISH:** `sensitivity_type='do not publish'`; when restricting, it contributes to `CLOSED` exposure like other restricting types.
- **Reviews:** internal review = `internal_review`; Advisory Council Review (ACR) = `advisory_council_review` (FOIA). Both restricting. While under review, `review_date` and `review_outcome` are `null`; the outcome is recorded on the next status transition (`active` or `cancelled`) with `review_date` and `review_outcome` (`upheld`/`lifted`).
- **Expiry checker:** manual only. `./scripts/check-sensitivity-expiry.sh` finds `active` sensitivities where `sensitivity_end < current_date` (including MANUAL) and emits deterministic idempotent `U` events setting `sensitivity_status='expired'`.

## Lifecycle examples

Examples align with `events/lifecycle` and `scripts/demo-lifecycle.sh`. Stored `archive.sensitivity` is authoritative; `archive.current_version_display.sensitivity_exposure` is derived.

### Lifecycle A - FOIA review on redacted title

Target: redacted title `...0013` (`en_r_1`) on version `...0006`.

#### A1. Seeded: internal review pending

`archive.sensitivity`

| sensitivity_id | target_version_title_id | type       | status          | start      | rule             | end        | review_date | review_outcome |
| -------------- | ----------------------- | ---------- | --------------- | ---------- | ---------------- | ---------- | ----------- | -------------- |
| `...0014`      | `...0013`               | FOIA/40(2) | internal_review | 2026-02-01 | JAN_AFTER_PERIOD | 2029-01-01 | *null*      | *null*         |

`archive.current_version_display`

| record_reference | version_code | default_title        | sensitivity_exposure |
| ---------------- | ------------ | -------------------- | -------------------- |
| REC-001          | en_1         | Demonstration record | PARTIALLY_OPEN       |

Interpretation: redacted title is restricting while under review; other version targets are unrestricted.

#### A2. Internal review outcome: sensitivity upheld

Event: `events/lifecycle/02_foia_internal_review_outcome_active.json`

`archive.sensitivity`

| sensitivity_id | status | review_date | review_outcome | sensitivity_end | exposure       |
| -------------- | ------ | ----------- | -------------- | --------------- | -------------- |
| `...0014`      | active | 2026-11-18  | upheld         | 2029-01-01      | PARTIALLY_OPEN |

Interpretation: review completed; outcome recorded on next status (`active`).

#### A3. Enter Advisory Council Review: outcome pending

Event: `events/lifecycle/03_foia_enter_acr.json`

`archive.sensitivity`

| sensitivity_id | status                  | review_date | review_outcome | exposure       |
| -------------- | ----------------------- | ----------- | -------------- | -------------- |
| `...0014`      | advisory_council_review | *null*      | *null*         | PARTIALLY_OPEN |

Interpretation: under review, so no review date/outcome yet.

#### A4. ACR outcome: sensitivity lifted / no longer required

Event: `events/lifecycle/04_foia_acr_outcome_cancelled.json`

`archive.sensitivity`

| sensitivity_id | status    | review_date | review_outcome | exposure |
| -------------- | --------- | ----------- | -------------- | -------- |
| `...0014`      | cancelled | 2026-11-21  | lifted         | OPEN     |

Interpretation: outcome recorded on next status (`cancelled`); no restricting sensitivities remain.

### Lifecycle B - Add restricting sensitivities (AUR + do not publish)

Event: `events/lifecycle/05_add_aur_and_dnp.json`

`archive.sensitivity` (rows added)

| sensitivity_id | target            | type           | status | start      | rule         | end        | review_date | review_outcome |
| -------------- | ----------------- | -------------- | ------ | ---------- | ------------ | ---------- | ----------- | -------------- |
| `...0015`      | title `...0005`   | AUR/AUR-001    | active | 2026-11-22 | EXACT_PERIOD | 2027-05-22 | *null*      | *null*         |
| `...0016`      | version `...0006` | do not publish | active | 2026-11-22 | MANUAL       | *null*     | *null*      | *null*         |

`archive.current_version_display`

| record_reference | version_code | default_title        | sensitivity_exposure |
| ---------------- | ------------ | -------------------- | -------------------- |
| REC-001          | en_1         | Demonstration record | CLOSED               |

Interpretation: AUR restricts original title; `do not publish` is restricting and makes version exposure `CLOSED` in current PoC.

### Lifecycle C - Manual expiry

Event: `events/lifecycle/06_expired_candidate.json`, then `./scripts/check-sensitivity-expiry.sh`.

`archive.sensitivity`

| sensitivity_id | target_description_id | type       | status before checker | sensitivity_end | status after checker | rerun           |
| -------------- | --------------------- | ---------- | --------------------- | --------------- | -------------------- | --------------- |
| `...0017`      | `...0007`             | FOIA/40(2) | active                | 2021-01-01      | expired              | duplicate/no-op |

Interpretation: manual checker emits deterministic idempotent expiry event; rerun is safe.

## Command/event examples

```bash
# curated demos (reset data by default)
./scripts/demo-lifecycle.sh
./scripts/demo-expiry.sh
./scripts/demo-batching.sh
./scripts/demo-sqs.sh

# individual lifecycle events
./scripts/send-events.sh events/lifecycle/02_foia_internal_review_outcome_active.json lambda
./scripts/send-events.sh events/lifecycle/03_foia_enter_acr.json lambda
./scripts/send-events.sh events/lifecycle/04_foia_acr_outcome_cancelled.json lambda

# manual expiry checker
./scripts/check-sensitivity-expiry.sh
```
