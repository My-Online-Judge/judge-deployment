#!/usr/bin/env bash
# Sub-project 3b: builds submission-db's schema with oj-submission-service's own Flyway scripts, in a one-shot
# flyway/flyway container — never by starting submission-service early: it would join consumer group
# judge-api-results next to the running service and take verdicts for submissions it does not have. Same Flyway
# as Spring Boot 3.5.16 (11.7.2), so the service later finds a history it accepts.
# Defaults target the live stack; the rehearsal overrides NETWORK (oj-net), DB_HOST (submission-db) and the
# database settings (SUBMISSION_DB / _USER / _PASSWORD, else read from .env.submission).
set -euo pipefail
cd "$(dirname "$0")/.."
val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
migrations=$(cd ../oj-submission-service/src/main/resources/db/migration && pwd)
env_file=$(mktemp)
trap 'rm -f "$env_file"' EXIT
chmod 600 "$env_file"
{
    echo "FLYWAY_URL=jdbc:postgresql://${DB_HOST:-submission-db}:5432/${SUBMISSION_DB:-$(val POSTGRES_DB .env.submission)}"
    echo "FLYWAY_USER=${SUBMISSION_USER:-$(val POSTGRES_USER .env.submission)}"
    echo "FLYWAY_PASSWORD=${SUBMISSION_PASSWORD:-$(val POSTGRES_PASSWORD .env.submission)}"
    echo "FLYWAY_CONNECT_RETRIES=10"
} > "$env_file"
docker run --rm --network "${NETWORK:-oj-net}" --env-file "$env_file" \
    -v "$migrations:/flyway/sql:ro" flyway/flyway:11.7.2 -q migrate
docker run --rm --network "${NETWORK:-oj-net}" --env-file "$env_file" \
    -v "$migrations:/flyway/sql:ro" flyway/flyway:11.7.2 info | grep -E "^\| (Versioned|Success)|^\| Category|Success" | sed 's/  */ /g'
