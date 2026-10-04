#!/usr/bin/env bash
# Checks migrations/sp3-backup-oj-db.sh against a throwaway Postgres standing in for oj-db: the dump is written
# owner-only, pg_restore can read it back, every table's data is in it, and a second run never overwrites a backup.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
db=oj-backup-test-$$
cleanup() { docker rm -f "$db" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
docker run -d --name "$db" -e POSTGRES_USER=oj -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=my_oj postgres:16 >/dev/null
for _ in $(seq 1 60); do docker exec "$db" pg_isready -q -h 127.0.0.1 -U oj -d my_oj && break; sleep 1; done
docker exec "$db" psql -q -U oj -d my_oj -c "CREATE TABLE t_submissions (id int); INSERT INTO t_submissions VALUES (1), (2);
                                            CREATE TABLE t_users (id int); INSERT INTO t_users VALUES (1);"

out=$(DB_CONTAINER="$db" BACKUP_DIR="$work" "$here/sp3-backup-oj-db.sh")
dump=$(ls "$work"/oj-db-final-*.dump)
second=$(DB_CONTAINER="$db" BACKUP_DIR="$work" "$here/sp3-backup-oj-db.sh" 2>&1 || true)

fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $3, got $2"; fail=1; fi
}
check "one dump is written" "$(ls "$work" | grep -c '^oj-db-final-.*\.dump$')" 1
check "the dump is owner-only" "$(stat -c %a "$dump")" 600
check "pg_restore lists both tables' data" \
    "$(docker run --rm -v "$work:/b:ro" postgres:16 pg_restore --list "/b/$(basename "$dump")" | grep -c 'TABLE DATA public t_')" 2
check "the run reports the tables it checked" "$(printf '%s' "$out" | grep -c 'tables with data: 2')" 1
check "a second run does not overwrite the backup" "$(printf '%s' "$second" | grep -c 'exists')" 1
check "no password is printed" "$(printf '%s\n%s' "$out" "$second" | grep -c 'pw' || true)" 0
exit "$fail"
