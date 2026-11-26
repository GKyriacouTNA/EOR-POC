#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/demo-lib.sh"

reset_data "${1:-}"

step "1) Create past-end active FOIA sensitivity"
send_lambda "$root/events/lifecycle/06_expired_candidate.json"
show_table "archive.sensitivity (candidate row)" \
  "SELECT sensitivity_id, version_description_id, sensitivity_type, sensitivity_status,
          sensitivity_start, sensitivity_period, sensitivity_rule, sensitivity_end, updated_at
   FROM archive.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000017';"
pause

step "2) Run manual expiry checker"
printf '\n-- Command --\n%s\n\n' "./scripts/check-sensitivity-expiry.sh"
"$root/scripts/check-sensitivity-expiry.sh"
show_table "archive.sensitivity (after expiry checker)" \
  "SELECT sensitivity_id, sensitivity_status, sensitivity_end, updated_at
   FROM archive.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000017';"
show_table "archive.metadata_change_event (expiry audit rows)" \
  "SELECT event_group_id, source_event_id, entity_type, change_type, outcome, processing_status, changes
   FROM archive.metadata_change_event
   WHERE entity_id='10000000-0000-4000-8000-000000000017'
   ORDER BY processed_at;"
show_table "history.sensitivity (SCD2 for candidate)" \
  "SELECT sensitivity_status, sensitivity_end, valid_from, valid_to, is_current, source_event_id
   FROM history.sensitivity
   WHERE sensitivity_id='10000000-0000-4000-8000-000000000017'
   ORDER BY valid_from;"
pause

step "3) Rerun expiry checker (idempotency)"
printf '\n-- Command --\n%s\n\n' "./scripts/check-sensitivity-expiry.sh"
"$root/scripts/check-sensitivity-expiry.sh"
show_table "archive.metadata_change_event (all audit rows for candidate)" \
  "SELECT event_group_id, source_event_id, change_type, outcome, processing_status, processed_at
   FROM archive.metadata_change_event
   WHERE entity_id='10000000-0000-4000-8000-000000000017'
   ORDER BY processed_at;"
show_table "Idempotency summary" \
  "SELECT COUNT(*) AS audit_rows,
          COUNT(*) FILTER (WHERE outcome='applied') AS applied,
          COUNT(*) FILTER (WHERE outcome='duplicate') AS duplicate
   FROM archive.metadata_change_event
   WHERE entity_id='10000000-0000-4000-8000-000000000017';"

echo ""
echo "Expiry demo complete."
