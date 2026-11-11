#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$root/.env.example"; set +a
q="$(aws sqs get-queue-url --queue-name metadata-change-events --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
for index in 0 1 2; do
  event="$(jq -c ".[$index]" "$root/events.json")"
  echo "Sending this JSON message to SQS:"; jq ".[$index]" "$root/events.json"
  aws sqs send-message --queue-url "$q" --message-body "$event" --endpoint-url "$AWS_ENDPOINT_URL"
done
echo "Three messages sent. Wait a few seconds, then run: ./scripts/show-archival-demo.sh"
