#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
set -a; . "$ROOT/.env.example"; set +a

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }
pause() {
  if [ -t 0 ]; then
    read -r -p $'\nPress Enter to continue...' _
  fi
}

db_endpoint() {
  if [ -z "${DEMO_DB_HOST:-}" ] || [ -z "${DEMO_DB_PORT:-}" ]; then
    DEMO_DB_HOST="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].Endpoint.Address' --output text)"
    DEMO_DB_PORT="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].Endpoint.Port' --output text)"
    export DEMO_DB_HOST DEMO_DB_PORT
  fi
}

psqlq() {
  db_endpoint
  PGPASSWORD="$LOCAL_RDS_PASSWORD" psql \
    --host "$DEMO_DB_HOST" --port "$DEMO_DB_PORT" \
    --username "$LOCAL_RDS_USERNAME" --dbname "$LOCAL_RDS_DATABASE" \
    -v ON_ERROR_STOP=1 -P pager=off -P footer=off "$@"
}

show_json() {
  local file="$1"
  printf '\n-- JSON: %s --\n' "$file"
  jq . "$file"
}

send_lambda() {
  local file="$1"
  local out="/tmp/demo-send-response.json"
  show_json "$file"
  printf '\n-- Lambda invoke --\n'
  aws lambda invoke --function-name metadata-change-processor \
    --payload "$(jq -c '.' "$file")" \
    --cli-binary-format raw-in-base64-out \
    --endpoint-url "$AWS_ENDPOINT_URL" "$out" >/dev/null
  jq -r '"event_group_id: " + (.event_group_id // "n/a")' "$out"
  jq . "$out"
  LAST_EVENT_GROUP_ID="$(jq -r '.event_group_id // empty' "$out")"
  export LAST_EVENT_GROUP_ID
}

send_sqs() {
  local file="$1"
  local q count
  q="$(aws sqs get-queue-url --queue-name metadata-change-events --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
  count="$(jq 'if type=="array" then length elif type=="object" and has("events") then (.events|length) else 1 end' "$file")"
  show_json "$file"
  printf '\n-- Sending %s event(s) to SQS --\n' "$count"
  jq -c 'if type=="array" then .[] elif type=="object" and has("events") then .events[] else . end' "$file" | while IFS= read -r event; do
    aws sqs send-message --queue-url "$q" --message-body "$event" --endpoint-url "$AWS_ENDPOINT_URL" >/dev/null
  done
  echo "Sent."
}

show_table() {
  local title="$1" sql="$2"
  printf '\n-- %s --\n' "$title"
  psqlq -c "$sql"
}

reset_data() {
  if [ "${1:-}" = "--no-reset" ]; then
    step "Skipping data reset (--no-reset)"
    return
  fi
  "$ROOT/scripts/reset-demo-data.sh"
}
