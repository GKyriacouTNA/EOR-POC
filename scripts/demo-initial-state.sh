#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$root/.env.example"; set +a

step() { printf '\n==> %s\n' "$*"; }

# Clean demo state: remove Floci/Compose state and the labelled local RDS data.
step "Cleaning previous demo state"
mapfile -t rds < <(docker ps -a --filter 'label=io.floci.resource-id=metadata-history-db' --format '{{.ID}}')
volumes=()
for id in "${rds[@]}"; do while IFS= read -r volume; do [ -n "$volume" ] && volumes+=("$volume"); done < <(docker inspect "$id" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}'); done
docker compose --project-directory "$root" down --volumes --remove-orphans
[ "${#rds[@]}" -eq 0 ] || docker rm --force "${rds[@]}"
[ "${#volumes[@]}" -eq 0 ] || docker volume rm "${volumes[@]}"

step "Starting Floci"
docker compose --project-directory "$root" up -d floci

step "Creating SQS queues"
dlq="$(aws sqs create-queue --queue-name metadata-change-dlq --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
dlq_arn="$(aws sqs get-queue-attributes --queue-url "$dlq" --attribute-names QueueArn --endpoint-url "$AWS_ENDPOINT_URL" --query Attributes.QueueArn --output text)"
main="$(aws sqs create-queue --queue-name metadata-change-events --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
aws sqs set-queue-attributes --queue-url "$main" --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$dlq_arn\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" --endpoint-url "$AWS_ENDPOINT_URL"

step "Creating RDS instance ($LOCAL_RDS_INSTANCE_ID)"
aws rds create-db-instance --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --db-instance-class db.t3.micro --engine postgres --allocated-storage 20 --db-name "$LOCAL_RDS_DATABASE" --master-username "$LOCAL_RDS_USERNAME" --master-user-password "$LOCAL_RDS_PASSWORD" --endpoint-url "$AWS_ENDPOINT_URL" >/dev/null
echo "Waiting for RDS to become available..."
status=""
for i in $(seq 1 30); do
  status="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].DBInstanceStatus' --output text)"
  printf '  [%d/30] status=%s\n' "$i" "$status"
  [ "$status" = "available" ] && break
  sleep 1
done
if [ "$status" != "available" ]; then
  echo "RDS did not become available in time (last status: $status)" >&2
  exit 1
fi
host="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].Endpoint.Address' --output text)"
port="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].Endpoint.Port' --output text)"
echo "RDS endpoint: $host:$port"

step "Applying schema"
PGPASSWORD="$LOCAL_RDS_PASSWORD" psql --host "$host" --port "$port" --username "$LOCAL_RDS_USERNAME" --dbname "$LOCAL_RDS_DATABASE" --file "$root/schema.sql"

step "Installing Lambda dependencies"
rm -rf "$root/lambda/vendor"
python3 -m pip install --quiet --disable-pip-version-check 'pg8000==1.31.5' 'scramp==1.4.5' --target "$root/lambda/vendor"

step "Creating Lambda function"
env="Variables={DB_HOST=$host,DB_PORT=$port,DB_NAME=$LOCAL_RDS_DATABASE,DB_USERNAME=$LOCAL_RDS_USERNAME,DB_PASSWORD=$LOCAL_RDS_PASSWORD}"
aws lambda create-function --function-name metadata-change-processor --runtime python3.12 --role arn:aws:iam::000000000000:role/local-lambda-role --handler handler.handler --timeout 30 --memory-size 256 --environment "$env" --code "S3Bucket=hot-reload,S3Key=$root/lambda" --endpoint-url "$AWS_ENDPOINT_URL" >/dev/null

step "Seeding initial events via Lambda"
total="$(jq length "$root/initial_event.json")"
for i in $(seq 0 $((total - 1))); do
  event="$(jq -c ".[$i]" "$root/initial_event.json")"
  etype="$(jq -r '.entity_type' <<<"$event")"
  eid="$(jq -r '.entity_key | to_entries[0].value' <<<"$event")"
  printf '  [%d/%d] %s %s ... ' "$((i + 1))" "$total" "$etype" "$eid"
  out="/tmp/init-event-$i.json"
  aws lambda invoke --function-name metadata-change-processor --payload "$event" --cli-binary-format raw-in-base64-out --endpoint-url "$AWS_ENDPOINT_URL" "$out" >/dev/null
  if jq -e 'if type=="object" then has("errorMessage") or has("FunctionError") else false end' "$out" >/dev/null 2>&1; then
    echo "FAILED" >&2
    cat "$out" >&2
    exit 1
  fi
  outcome="$(jq -r 'if type=="object" and .outcome then .outcome else "ok" end' "$out")"
  echo "$outcome"
done

step "Creating SQS -> Lambda event-source mapping"
arn="$(aws sqs get-queue-attributes --queue-url "$main" --attribute-names QueueArn --endpoint-url "$AWS_ENDPOINT_URL" --query Attributes.QueueArn --output text)"
aws lambda create-event-source-mapping --function-name metadata-change-processor --event-source-arn "$arn" --batch-size 2 --function-response-types ReportBatchItemFailures --endpoint-url "$AWS_ENDPOINT_URL" >/dev/null

step "Initial archival state ready"
echo "Next: ./scripts/show-archival-demo.sh, then ./scripts/demo-send-three-changes.sh"
