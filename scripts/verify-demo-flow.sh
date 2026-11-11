#!/usr/bin/env bash
set -euo pipefail

# Read-only evidence for the completed SQS -> Lambda -> RDS demo flow.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$root/.env.example"; set +a
main="$(aws sqs get-queue-url --queue-name metadata-change-events --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
dlq="$(aws sqs get-queue-url --queue-name metadata-change-dlq --endpoint-url "$AWS_ENDPOINT_URL" --query QueueUrl --output text)"
host="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].Endpoint.Address' --output text)"
port="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].Endpoint.Port' --output text)"

printf '\n=== 1. SQS -> Lambda Mapping ===\n'
aws lambda list-event-source-mappings --function-name metadata-change-processor --endpoint-url "$AWS_ENDPOINT_URL" --query 'EventSourceMappings[].{State:State,Source:EventSourceArn,BatchSize:BatchSize,ResponseTypes:FunctionResponseTypes}' --output table

printf '\n=== 2. Queue State ===\n'
printf 'Main queue (should be empty after successful processing):\n'
curl --silent --get "$AWS_ENDPOINT_URL/_aws/sqs/messages" --data-urlencode "QueueUrl=$main"
printf '\nDLQ (should be empty for the three valid demo messages):\n'
curl --silent --get "$AWS_ENDPOINT_URL/_aws/sqs/messages" --data-urlencode "QueueUrl=$dlq"
printf '\n'

printf '\n=== 3. Lambda Execution Evidence ===\n'
stream="$(aws logs describe-log-streams --log-group-name /aws/lambda/metadata-change-processor --order-by LastEventTime --descending --limit 1 --endpoint-url "$AWS_ENDPOINT_URL" --query 'logStreams[0].logStreamName' --output text)"
printf 'Latest log stream: %s\n' "$stream"
aws logs get-log-events --log-group-name /aws/lambda/metadata-change-processor --log-stream-name "$stream" --endpoint-url "$AWS_ENDPOINT_URL" --query 'events[].message' --output text

printf '\n=== 4. Current RDS State ===\n'
PGPASSWORD="$LOCAL_RDS_PASSWORD" psql --host "$host" --port "$port" --username "$LOCAL_RDS_USERNAME" --dbname "$LOCAL_RDS_DATABASE" --command "SELECT * FROM archive.current_version_display; SELECT closure_id,status,updated_at FROM archive.closure;"

printf '\n=== 5. SCD Type 2 History ===\n'
PGPASSWORD="$LOCAL_RDS_PASSWORD" psql --host "$host" --port "$port" --username "$LOCAL_RDS_USERNAME" --dbname "$LOCAL_RDS_DATABASE" --command "SELECT 'version' AS entity,count(*) AS history_rows,count(*) FILTER (WHERE is_current) AS current_rows FROM history.version UNION ALL SELECT 'title',count(*),count(*) FILTER (WHERE is_current) FROM history.version_title WHERE version_title_id='10000000-0000-4000-8000-000000000013' UNION ALL SELECT 'closure',count(*),count(*) FILTER (WHERE is_current) FROM history.closure;"

printf '\n=== 6. SQS Event Audit ===\n'
PGPASSWORD="$LOCAL_RDS_PASSWORD" psql --host "$host" --port "$port" --username "$LOCAL_RDS_USERNAME" --dbname "$LOCAL_RDS_DATABASE" --command "SELECT entity_type,change_type,outcome,processing_status,changed_by_name,change_reason,changed_at FROM archive.metadata_change_event ORDER BY processed_at;"
