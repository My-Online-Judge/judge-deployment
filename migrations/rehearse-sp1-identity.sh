#!/usr/bin/env bash
# Cutover runbook step 2: rehearse the identity copy against a restored dump of the live oj-db,
# leaving the live databases untouched. Two throwaway Postgres containers stand in for oj-db and
# identity-db (the latter built from oj-identity-service's Flyway scripts), and the copy runs twice
# to prove it is re-runnable. Needs .env, .env.identity and the sibling ../oj-identity-service.
set -euo pipefail
cd "$(dirname "$0")/.."

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
NET=oj-rehearsal
SRC_DB=$(val DATABASE_NAME .env); SRC_USER=$(val DATABASE_USERNAME .env); SRC_PASS=$(val DATABASE_PASSWORD .env)
DST_DB=$(val POSTGRES_DB .env.identity); DST_USER=$(val POSTGRES_USER .env.identity); DST_PASS=$(val POSTGRES_PASSWORD .env.identity)

cleanup() {
    docker rm -f oj-rehearse-src oj-rehearse-dst >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null
docker run -d --name oj-rehearse-src --network "$NET" \
    -e POSTGRES_DB="$SRC_DB" -e POSTGRES_USER="$SRC_USER" -e POSTGRES_PASSWORD="$SRC_PASS" postgres:16 >/dev/null
docker run -d --name oj-rehearse-dst --network "$NET" \
    -e POSTGRES_DB="$DST_DB" -e POSTGRES_USER="$DST_USER" -e POSTGRES_PASSWORD="$DST_PASS" postgres:16 >/dev/null

# Over TCP only the final server answers (initdb's temporary one listens on the socket alone).
wait_ready() {
    for _ in $(seq 1 60); do
        docker exec "$1" pg_isready -q -h 127.0.0.1 -U "$2" -d "$3" && return 0
        sleep 1
    done
    echo "$1 did not become ready" >&2
    exit 1
}
wait_ready oj-rehearse-src "$SRC_USER" "$SRC_DB"
wait_ready oj-rehearse-dst "$DST_USER" "$DST_DB"

echo "== restoring a dump of the live oj-db"
docker exec oj-db pg_dump -U "$SRC_USER" -d "$SRC_DB" -Fc \
    | docker exec -i oj-rehearse-src pg_restore -U "$SRC_USER" -d "$SRC_DB" --no-owner --no-privileges

echo "== building identity-db from oj-identity-service's Flyway scripts"
for f in $(ls ../oj-identity-service/src/main/resources/db/migration/V*.sql | sort -V); do
    docker exec -i oj-rehearse-dst psql -q -v ON_ERROR_STOP=1 -U "$DST_USER" -d "$DST_DB" < "$f"
done

for run in 1 2; do
    echo "== copy, run $run"
    NETWORK="$NET" SRC_HOST=oj-rehearse-src DST_HOST=oj-rehearse-dst migrations/run-sp1-identity.sh
done
