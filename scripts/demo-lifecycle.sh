#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/demo-lib.sh"

reset_data "${1:-}"

step "Base state: seeded FOIA sensitivity (internal_review, no outcome yet)"
show_table "archive.sensitivity (seeded row)" \
  "SELECT sensitivity_id, version_title_id, sensitivity_type, sensitivity_status,
          sensitivity_start, sensitivity_end, review_date, review_outcome
   FROM archive.sensitivity
   WHERE sensitivity_id='10000000-0000-4000-8000-000000000014';"
show_table "archive.current_version_display (derived exposure)" \
  "SELECT record_reference, version_code, default_title, sensitivity_exposure
   FROM archive.current_version_display
   WHERE version_id='10000000-0000-4000-8000-000000000006';"
pause

step "1) Internal review outcome -> active (sensitivity upheld)"
send_lambda "$root/events/lifecycle/02_foia_internal_review_outcome_active.json"
show_table "archive.sensitivity (current row)" \
  "SELECT sensitivity_id, sensitivity_status, review_date, review_outcome, updated_at
   FROM archive.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014';"
show_table "history.sensitivity (SCD2 rows)" \
  "SELECT sensitivity_status, review_date, review_outcome, valid_from, valid_to, is_current
   FROM history.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014' ORDER BY valid_from;"
pause

step "2) Enter Advisory Council Review (no review date/outcome while under review)"
send_lambda "$root/events/lifecycle/03_foia_enter_acr.json"
show_table "archive.sensitivity (current row)" \
  "SELECT sensitivity_id, sensitivity_status, review_date, review_outcome, updated_at
   FROM archive.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014';"
show_table "history.sensitivity (SCD2 rows)" \
  "SELECT sensitivity_status, review_date, review_outcome, valid_from, valid_to, is_current
   FROM history.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014' ORDER BY valid_from;"
pause

step "3) ACR outcome -> cancelled (sensitivity lifted)"
send_lambda "$root/events/lifecycle/04_foia_acr_outcome_cancelled.json"
show_table "archive.sensitivity (current row)" \
  "SELECT sensitivity_id, sensitivity_status, review_date, review_outcome, updated_at
   FROM archive.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014';"
show_table "archive.current_version_display (exposure after release)" \
  "SELECT record_reference, version_code, default_title, sensitivity_exposure
   FROM archive.current_version_display WHERE version_id='10000000-0000-4000-8000-000000000006';"
show_table "history.sensitivity (SCD2 rows)" \
  "SELECT sensitivity_status, review_date, review_outcome, valid_from, valid_to, is_current
   FROM history.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014' ORDER BY valid_from;"
pause

step "4) Add AUR on original title + do not publish on version"
send_lambda "$root/events/lifecycle/05_add_aur_and_dnp.json"
show_table "archive.sensitivity (all current rows)" \
  "SELECT sensitivity_id, sensitivity_type, sensitivity_status, version_id, version_title_id, sensitivity_end, review_date, review_outcome
   FROM archive.sensitivity ORDER BY updated_at;"
show_table "archive.current_active_sensitivity (restricting rows only)" \
  "SELECT sensitivity_id, sensitivity_type, sensitivity_status, version_id, version_title_id
   FROM archive.current_active_sensitivity ORDER BY updated_at;"
show_table "archive.current_version_display (derived exposure)" \
  "SELECT record_reference, version_code, default_title, sensitivity_exposure
   FROM archive.current_version_display WHERE version_id='10000000-0000-4000-8000-000000000006';"

echo ""
echo "Lifecycle demo complete."
