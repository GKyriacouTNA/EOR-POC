# Events

Curated event files for demonstrating the PoC.

## Layout

- `seed/initial.json` - base archive graph seeded by `reset-demo-data.sh` / demo scripts.
- `lifecycle/` - sensitivity lifecycle steps.
- `bulk/` - batch wrapper and `entity_keys` same-change payloads.
- `demos/` - small composed flows.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/demo-initial-state.sh` | Build infra only: Floci, RDS, schema, Lambdas, SQS mapping. No data. |
| `scripts/reset-demo-data.sh` | Truncate archive/history data and reseed base data. Fast; no schema/container rebuild. |
| `scripts/demo-lifecycle.sh` | Interactive lifecycle demo: JSON, DB before/after, exposure/SCD2. |
| `scripts/demo-batching.sh` | Interactive batch demo: wrapper invoke, `entity_keys` expansion, audit evidence. |
| `scripts/demo-expiry.sh` | Interactive expiry demo: candidate, checker, idempotent rerun. |
| `scripts/demo-sqs.sh` | Interactive SQS demo: send to queue, wait, DB/queue evidence. |
| `scripts/send-events.sh <file> [lambda|sqs]` | Generic sender. |
| `scripts/check-sensitivity-expiry.sh` | Manual expiry checker. |

Demo scripts accept `--no-reset` to skip the data reset.
