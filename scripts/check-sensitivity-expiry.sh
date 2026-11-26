#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$root/.env.example"; set +a
out="/tmp/expiry-check.json"
echo "Invoking sensitivity-expiry-checker..."
aws lambda invoke --function-name sensitivity-expiry-checker --payload '{}' --cli-binary-format raw-in-base64-out --endpoint-url "$AWS_ENDPOINT_URL" "$out" >/dev/null
jq -r "\"event_group_id: \" + (.event_group_id // \"n/a\")" "$out"
jq . "$out"
