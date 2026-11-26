#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$root/.env.example"; set +a
file="${1:?usage: send-events.sh <file.json> [sqs|lambda]}"
mode="${2:-lambda}"
[ -f "$file" ] || { echo "file not found: $file" >&2; exit 1; }
payload="$(jq -c '.' "$file")"

if [ "$mode" = "lambda" ]; then
  out="/tmp/send-events-response.json"
  printf 'Invoking metadata-change-processor with %s\n' "$file"
  aws lambda invoke --function-name metadata-change-processor --payload "$payload" --cli-binary-format raw-in-base64-out --endpoint-url "$AWS_ENDPOINT_URL" "$out" >/dev/null
  jq . "$out"
  exit 0
fi

q="$(aws sqs get-queue-url --queue-name metadata-change-events --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
count="$(jq 'if type=="array" then length elif type=="object" and has("events") then (.events|length) else 1 end' "$file")"
printf 'Sending %s event(s) from %s to SQS\n' "$count" "$file"
jq -c 'if type=="array" then .[] elif type=="object" and has("events") then .events[] else . end' "$file" | while IFS= read -r event; do
  aws sqs send-message --queue-url "$q" --message-body "$event" --endpoint-url "$AWS_ENDPOINT_URL" >/dev/null
done
echo "Sent."
