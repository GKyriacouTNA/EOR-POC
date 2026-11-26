#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$root/.env.example"; set +a

step() { printf '\n==> %s\n' "$*"; }

host="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].Endpoint.Address' --output text)"
port="$(aws rds describe-db-instances --db-instance-identifier "$LOCAL_RDS_INSTANCE_ID" --endpoint-url "$AWS_ENDPOINT_URL" --query 'DBInstances[0].Endpoint.Port' --output text)"

step "Checking schema"
PGPASSWORD="$LOCAL_RDS_PASSWORD" psql --host "$host" --port "$port" --username "$LOCAL_RDS_USERNAME" --dbname "$LOCAL_RDS_DATABASE" -tAc \
  "SELECT 1 FROM pg_namespace WHERE nspname='archive'" | grep -q 1 || {
  echo "Schema missing. Run ./scripts/demo-initial-state.sh first." >&2; exit 1; }

step "Clearing data (keeping schema)"
PGPASSWORD="$LOCAL_RDS_PASSWORD" psql --host "$host" --port "$port" --username "$LOCAL_RDS_USERNAME" --dbname "$LOCAL_RDS_DATABASE" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname IN ('archive', 'history')
  LOOP
    EXECUTE format('TRUNCATE TABLE %I.%I CASCADE', r.schemaname, r.tablename);
  END LOOP;
END $$;
SQL

step "Seeding base data (batched)"
payload="$(jq -c '{events: .}' "$root/events/seed/initial.json")"
out="/tmp/reset-seed.json"
printf '  Sending %s seed events as one batch...\n' "$(jq length "$root/events/seed/initial.json")"
aws lambda invoke --function-name metadata-change-processor --payload "$payload" --cli-binary-format raw-in-base64-out --endpoint-url "$AWS_ENDPOINT_URL" "$out" >/dev/null
jq -e 'has("results")' "$out" >/dev/null || { cat "$out"; exit 1; }
jq -r '"  Seeded: \( .results | map(select(.outcome!="failed")) | length ) ok, \( .results | map(select(.outcome=="failed")) | length ) failed"' "$out"
