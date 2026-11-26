#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/demo-lib.sh"

reset_data "${1:-}"
if [ "${1:-}" != "--no-reset" ]; then
  step "Setup: add AUR + DNP sensitivities as multi-id targets"
  send_lambda "$root/events/lifecycle/05_add_aur_and_dnp.json"
  pause
fi

step "1) Batch wrapper: multiple events in one Lambda invocation/connection"
send_lambda "$root/events/bulk/batch_seed.json"
show_table "archive.department (created by batch)" \
  "SELECT department_id, department_code, name, updated_at
   FROM archive.department WHERE department_id='20000000-0000-4000-8000-000000000001';"
show_table "archive.series (created by batch)" \
  "SELECT series_id, department_id, series_code, name, updated_at
   FROM archive.series WHERE series_id='20000000-0000-4000-8000-000000000002';"
show_table "archive.record (created by batch)" \
  "SELECT record_id, series_id, record_reference, updated_at
   FROM archive.record WHERE record_id='20000000-0000-4000-8000-000000000003';"
batch_gid="$LAST_EVENT_GROUP_ID"
show_table "archive.metadata_change_event (batch wrapper audit rows)" \
  "SELECT event_group_id, source_event_id, entity_type, entity_id, change_type, outcome, processing_status
   FROM archive.metadata_change_event
   WHERE event_group_id='${batch_gid}'
   ORDER BY processed_at;"
pause

step "2) entity_keys: same change applied to multiple sensitivities"
show_table "archive.sensitivity BEFORE multi-id update" \
  "SELECT sensitivity_id, sensitivity_type, sensitivity_status, archivist_note
   FROM archive.sensitivity ORDER BY updated_at, sensitivity_id;"
send_lambda "$root/events/bulk/multi_id_same_change.json"
multi_gid="$LAST_EVENT_GROUP_ID"
show_table "archive.sensitivity AFTER multi-id update" \
  "SELECT sensitivity_id, sensitivity_type, sensitivity_status, archivist_note, updated_at
   FROM archive.sensitivity ORDER BY updated_at, sensitivity_id;"
show_table "archive.metadata_change_event (multi-id bulk audit rows)" \
  "SELECT event_group_id, source_event_id, entity_type, entity_id, change_type, outcome, processing_status
   FROM archive.metadata_change_event
   WHERE event_group_id='${multi_gid}'
   ORDER BY processed_at;"
show_table "history.sensitivity (rows created by multi-id update)" \
  "SELECT sensitivity_id, sensitivity_status, archivist_note, valid_from, valid_to, is_current, source_event_id
   FROM history.sensitivity
   WHERE source_event_id IN (
     SELECT source_event_id FROM archive.metadata_change_event WHERE event_group_id='${multi_gid}')
   ORDER BY sensitivity_id, valid_from;"

echo ""
echo "Batching demo complete."
