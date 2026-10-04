#!/usr/bin/env bash
# Checks migrations/sp2-env.sh on a throwaway copy: .env.problem is owner-only, the service token lands in
# .env exactly once, a second run changes nothing, and no secret value is ever printed.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/migrations"
cp "$here/sp2-env.sh" "$work/migrations/"
cat > "$work/.env" <<'ENV'
SPRING_PROFILES_ACTIVE=prod
DATABASE_PASSWORD=oj-db-secret
KAFKA_BROKERS=kafka:29092
ENV
chmod 664 "$work/.env"

out1=$("$work/migrations/sp2-env.sh")
sum_env=$(md5sum < "$work/.env"); sum_problem=$(md5sum < "$work/.env.problem")
out2=$("$work/migrations/sp2-env.sh")

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
token=$(val PROBLEM_RPC_TOKEN "$work/.env")
password=$(val POSTGRES_PASSWORD "$work/.env.problem")

fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $3, got $2"; fail=1; fi
}
check ".env.problem is owner-only" "$(stat -c %a "$work/.env.problem")" 600
check "the token is added to .env once" "$(grep -c '^PROBLEM_RPC_TOKEN=' "$work/.env")" 1
check "the token is 64 hex characters" "$(printf '%s' "$token" | grep -cE '^[0-9a-f]{64}$')" 1
check "problem-service connects with the database password" "$(val DATABASE_PASSWORD "$work/.env.problem")" "$password"
check "problem-service runs the prod profile" "$(val SPRING_PROFILES_ACTIVE "$work/.env.problem")" prod
check ".env keeps its own settings" "$(val DATABASE_PASSWORD "$work/.env")" oj-db-secret
check "a second run leaves .env alone" "$(md5sum < "$work/.env")" "$sum_env"
check "a second run leaves .env.problem alone" "$(md5sum < "$work/.env.problem")" "$sum_problem"
check "no secret is printed" "$(printf '%s\n%s\n' "$out1" "$out2" | grep -cF -e "$token" -e "$password" || true)" 0
exit "$fail"
