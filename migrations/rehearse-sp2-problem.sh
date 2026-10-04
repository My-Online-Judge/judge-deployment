#!/usr/bin/env bash
# Cutover runbook: rehearse the problem copy against a restored dump of the live oj-db, leaving the live
# databases untouched. Two throwaway Postgres containers stand in for oj-db and problem-db (the latter built
# from oj-problem-service's Flyway scripts). The copy runs twice to prove it is re-runnable; then two
# tampered values (a test case's sample flag, a statistics count) must each make the verification fail,
# and a problem-db that has moved on (as after the go-live) must make a new copy refuse unless FORCE=1.
# Needs .env, .env.problem (migrations/sp2-env.sh) and the sibling ../oj-problem-service.
set -euo pipefail
cd "$(dirname "$0")/.."

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
NET=oj-rehearsal
SRC_DB=$(val DATABASE_NAME .env); SRC_USER=$(val DATABASE_USERNAME .env); SRC_PASS=$(val DATABASE_PASSWORD .env)
DST_DB=$(val POSTGRES_DB .env.problem); DST_USER=$(val POSTGRES_USER .env.problem); DST_PASS=$(val POSTGRES_PASSWORD .env.problem)

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

echo "== building problem-db from oj-problem-service's Flyway scripts"
for f in $(ls ../oj-problem-service/src/main/resources/db/migration/V*.sql | sort -V); do
    docker exec -i oj-rehearse-dst psql -q -v ON_ERROR_STOP=1 -U "$DST_USER" -d "$DST_DB" < "$f"
done

run() { FORCE="${FORCE:-}" NETWORK="$NET" SRC_HOST=oj-rehearse-src DST_HOST=oj-rehearse-dst migrations/run-sp2-problem.sh "$@"; }
for n in 1 2; do
    echo "== copy, run $n"
    run copy
done

dst_sql() { docker exec oj-rehearse-dst psql -XAtq -v ON_ERROR_STOP=1 -U "$DST_USER" -d "$DST_DB" -c "$1"; }
tamper() {   # name, breaking SQL, restoring SQL
    echo "== tamper: $1 (the verification must fail)"
    dst_sql "$2"
    if run verify; then
        echo "REHEARSAL FAILED: the verification missed '$1'" >&2
        exit 1
    fi
    dst_sql "$3"
    echo "-- caught; restored"
}
tamper "a test case's sample flag" \
    "UPDATE t_test_cases SET is_sample = NOT is_sample WHERE id = (SELECT min(id::text)::uuid FROM t_test_cases)" \
    "UPDATE t_test_cases SET is_sample = NOT is_sample WHERE id = (SELECT min(id::text)::uuid FROM t_test_cases)"
tamper "one statistics count" \
    "UPDATE t_problem_stats SET submission_count = submission_count + 1 WHERE (problem_id, verdict) = (SELECT problem_id, verdict FROM t_problem_stats ORDER BY 1, 2 LIMIT 1)" \
    "UPDATE t_problem_stats SET submission_count = submission_count - 1 WHERE (problem_id, verdict) = (SELECT problem_id, verdict FROM t_problem_stats ORDER BY 1, 2 LIMIT 1)"

echo "== after restoring both values"
run verify

echo "== problem-db holds a verdict oj-db does not (as after the go-live): a copy must refuse"
dst_sql "INSERT INTO t_processed_verdicts (submission_id, processed_at) VALUES ('$(cat /proc/sys/kernel/random/uuid)', now())"
before=$(dst_sql "SELECT count(*) FROM t_processed_verdicts")
if run copy; then
    echo "REHEARSAL FAILED: a copy replaced a problem-db that had moved on" >&2
    exit 1
fi
[ "$(dst_sql "SELECT count(*) FROM t_processed_verdicts")" = "$before" ] \
    || { echo "REHEARSAL FAILED: the refused copy changed problem-db" >&2; exit 1; }
echo "-- refused, problem-db untouched; FORCE=1 overrides"
FORCE=1 run copy
echo "REHEARSAL OK"
