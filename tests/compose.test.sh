#!/usr/bin/env bash
# Checks on the resolved compose file (sub-project 4). Prints key names only, never a value.
# Run from anywhere: tests/compose.test.sh — needs the gitignored .env* files beside docker-compose.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
config=$(docker compose config --format json)
fail=0
check() { # check <description> <python expression over s = services, v = volumes>
  if python3 -c "import json,sys; c=json.load(sys.stdin); s=c['services']; v=c.get('volumes',{}); sys.exit(0 if ($2) else 1)" <<< "$config"; then
    echo "ok   $1"
  else
    echo "FAIL $1"; fail=1
  fi
}

worker_allowlist="['JUDGE_SERVER_TOKEN','JUDGE_SERVER_URL','KAFKA_BROKERS','MINIO_ACCESS_KEY','MINIO_BUCKET','MINIO_ENDPOINT',
  'MINIO_SECRET_KEY','OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL','OTEL_LOGS_EXPORTER','OTEL_METRICS_EXPORTER',
  'OTEL_SERVICE_NAME','TZ']"
# The resolved config inlines an env_file into environment, so this one check also catches an env_file coming back.
check "judge-worker gets exactly the variables it reads" "sorted(s['judge-worker']['environment']) == $worker_allowlist"

check "kafka keeps its logs on the named volume kafkadata" \
  "s['kafka']['environment'].get('KAFKA_LOG_DIRS') == '/var/lib/kafka/data' and any(m.get('source') == 'kafkadata' and m.get('target') == '/var/lib/kafka/data' for m in s['kafka'].get('volumes', [])) and 'kafkadata' in v"
check "kafka has a fixed cluster id" "s['kafka']['environment'].get('CLUSTER_ID') == 'LL99FafWSZyhNAgsibWLog'"

check "api-gateway waits only for the back-ends to start, and for redis to be healthy" \
  "{k: d['condition'] for k, d in s['api-gateway']['depends_on'].items()} == {'submission-service': 'service_started', 'identity-service': 'service_started', 'problem-service': 'service_started', 'redis': 'service_healthy'}"
check "problem-service gets KAFKA_PARTITIONS" "s['problem-service']['environment'].get('KAFKA_PARTITIONS') == '6'"

exit $fail
