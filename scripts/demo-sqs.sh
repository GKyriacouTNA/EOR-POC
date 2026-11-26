#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/demo-lib.sh"

reset_data "${1:-}"

step "1) Base state before SQS flow"
show_table "archive.sensitivity (seeded FOIA)" \
  "SELECT sensitivity_id, sensitivity_status, review_date, review_outcome, updated_at
   FROM archive.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014';"
pause

step "2) Send lifecycle events through SQS event-source mapping"
send_sqs "$root/events/demos/full_lifecycle.json"
echo "Waiting for async Lambda processing..."
sleep 4

show_table "archive.sensitivity (after SQS processing)" \
  "SELECT sensitivity_id, sensitivity_status, review_date, review_outcome, updated_at
   FROM archive.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014';"
show_table "history.sensitivity (SCD2 from SQS flow)" \
  "SELECT sensitivity_status, review_date, review_outcome, valid_from, valid_to, is_current
   FROM history.sensitivity WHERE sensitivity_id='10000000-0000-4000-8000-000000000014' ORDER BY valid_from;"
show_table "archive.metadata_change_event (recent audit rows)" \
  "SELECT event_group_id, source_event_id, entity_type, change_type, outcome, processing_status, source_system
   FROM archive.metadata_change_event ORDER BY processed_at DESC LIMIT 8;"

printf '\n-- SQS queue attributes (main) --\n'
q_main="$(aws sqs get-queue-url --queue-name metadata-change-events --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
aws sqs get-queue-attributes --queue-url "$q_main" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --endpoint-url "$AWS_ENDPOINT_URL" --output json

printf '\n-- SQS queue attributes (DLQ) --\n'
q_dlq="$(aws sqs get-queue-url --queue-name metadata-change-dlq --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
aws sqs get-queue-attributes --queue-url "$q_dlq" \
  --attribute-names ApproximateNumberOfMessages \
  --endpoint-url "$AWS_ENDPOINT_URL" --output json

echo ""
echo "SQS demo complete."
