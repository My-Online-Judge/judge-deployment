#!/usr/bin/env bash
# Checks migrations/sp3-env.sh on a throwaway copy: create writes .env.submission owner-only and is idempotent;
# strip removes oj-db's DATABASE_* settings from .env (and only those), keeping an owner-only backup; no secret
# value is ever printed.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/migrations"
cp "$here/sp3-env.sh" "$work/migrations/"
cat > "$work/.env" <<'ENV'
SPRING_PROFILES_ACTIVE=prod
DATABASE_URL=jdbc:postgresql://db:5432/my_oj
DATABASE_USERNAME=postgres
DATABASE_PASSWORD=oj-db-secret
DATABASE_NAME=my_oj
KAFKA_BROKERS=kafka:29092
PROBLEM_RPC_TOKEN=token-value
ENV
chmod 664 "$work/.env"

out1=$("$work/migrations/sp3-env.sh" create)
sum_submission=$(md5sum < "$work/.env.submission")
out2=$("$work/migrations/sp3-env.sh" create)
out3=$("$work/migrations/sp3-env.sh" strip)
out4=$("$work/migrations/sp3-env.sh" strip)

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
password=$(val POSTGRES_PASSWORD "$work/.env.submission")

fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $3, got $2"; fail=1; fi
}
check ".env.submission is owner-only" "$(stat -c %a "$work/.env.submission")" 600
check "submission-service connects with the database password" "$(val DATABASE_PASSWORD "$work/.env.submission")" "$password"
check "submission-service connects to submission-db" "$(val DATABASE_URL "$work/.env.submission")" "jdbc:postgresql://submission-db:5432/submission"
check "submission-service runs the prod profile" "$(val SPRING_PROFILES_ACTIVE "$work/.env.submission")" prod
check "a second create leaves .env.submission alone" "$(md5sum < "$work/.env.submission")" "$sum_submission"
check "strip removes oj-db's settings" "$(grep -c '^DATABASE_' "$work/.env" || true)" 0
check "strip keeps the rest" "$(val PROBLEM_RPC_TOKEN "$work/.env"),$(val KAFKA_BROKERS "$work/.env")" "token-value,kafka:29092"
check "the backup is owner-only" "$(stat -c %a "$work/.env.pre-sp3b")" 600
check "the backup holds what was stripped" "$(val DATABASE_PASSWORD "$work/.env.pre-sp3b")" oj-db-secret
check "no secret is printed" "$(printf '%s\n' "$out1" "$out2" "$out3" "$out4" | grep -cF -e "$password" -e oj-db-secret -e token-value || true)" 0
exit "$fail"
