#!/usr/bin/env bash
# Checks migrations/sp12-env.sh on fixture env files in a temp dir (never the real ones): create twice is idempotent,
# the access-token lifetime is 900000, Grafana and pg_monitor get hex passwords that survive a second run, the queue cap
# is 200 only where it was absent, examples and sp10 backups are not backed up again, modes are 600, nothing secret is
# printed, the Telegram keys are not generated, compose renders with the migrated files; restore gives back the bytes.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
w2=$(mktemp -d)
trap 'rm -rf "$work" "$w2"' EXIT
mkdir "$work/migrations" "$work/orig" "$w2/migrations"
cp "$here/migrations/sp12-env.sh" "$work/migrations/" 2>/dev/null || true
cp "$here/migrations/sp12-env.sh" "$w2/migrations/" 2>/dev/null || true
cat > "$work/.env" <<'ENV'
SPRING_PROFILES_ACTIVE=prod
JUDGE_SERVER_TOKEN=judge-token-secret
KAFKA_BROKERS=kafka:29092
MINIO_ROOT_USER=rootuser-value
MINIO_ROOT_PASSWORD=rootpass-value
OJ_PUBLIC_HOST=oj.example.test
ENV
cat > "$work/.env.identity" <<'ENV'
POSTGRES_DB=identity
POSTGRES_USER=identity
POSTGRES_PASSWORD=identity-db-secret
JWT_RSA_PRIVATE_KEY=jwt-private-secret
JWT_ACCESS_TOKEN_EXPIRATION=3600000
GOOGLE_CLIENT_SECRET=google-secret-value
ENV
printf 'POSTGRES_DB=identity\nPOSTGRES_USER=identity\nPOSTGRES_PASSWORD=identity-db-secret\n' > "$work/.env.identity-db"
printf 'POSTGRES_PASSWORD=problem-db-secret\n' > "$work/.env.problem"
printf 'POSTGRES_PASSWORD=submission-db-secret\nJUDGE_REQUEST_TIMEOUT=30m\n' > "$work/.env.submission"
echo 'EXAMPLE=do-not-copy' > "$work/.env.example"
echo 'OLD=sp10-backup' > "$work/.env.pre-sp10"
chmod 664 "$work/.env" "$work/.env.identity"
chmod 640 "$work/.env.problem"
files=(.env .env.identity .env.identity-db .env.problem .env.submission)
for f in "${files[@]}"; do cp -p "$work/$f" "$work/orig/$f"; done

out1=$("$work/migrations/sp12-env.sh" create)
snap1=$(cd "$work" && md5sum "${files[@]}")
out2=$("$work/migrations/sp12-env.sh" create)
snap2=$(cd "$work" && md5sum "${files[@]}")

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $3, got $2"; fail=1; fi
}
gpw=$(val GRAFANA_ADMIN_PASSWORD "$work/.env")
pgpw=$(val PG_MONITOR_PASSWORD "$work/.env")
check "access tokens last 900000 ms" "$(grep -c '^JWT_ACCESS_TOKEN_EXPIRATION=900000$' "$work/.env.identity")" 1
check "the expiration key appears once" "$(grep -c '^JWT_ACCESS_TOKEN_EXPIRATION=' "$work/.env.identity")" 1
check "GRAFANA_ADMIN_PASSWORD is 32 hex" "$(grep -cE '^[0-9a-f]{32}$' <<< "$gpw" || true)" 1
check "PG_MONITOR_PASSWORD is 48 hex" "$(grep -cE '^[0-9a-f]{48}$' <<< "$pgpw" || true)" 1
check "a second create changes nothing (all files)" "$snap2" "$snap1"
check "JUDGE_MAX_QUEUE_DEPTH is 200 after the first run" "$(val JUDGE_MAX_QUEUE_DEPTH "$work/.env.submission")" 200
check "the rest of .env.submission is kept" "$(val JUDGE_REQUEST_TIMEOUT "$work/.env.submission")" 30m
check "the rest of .env is kept" "$(val KAFKA_BROKERS "$work/.env"),$(val OJ_PUBLIC_HOST "$work/.env")" "kafka:29092,oj.example.test"
check "the Telegram keys are not generated" "$(cat "$work"/.env* | grep -c '^ALERT_TELEGRAM' || true)" 0
check "no OJ_ key is added" "$(cat "$work/.env.identity" "$work/.env.submission" | grep -c '^OJ_' || true)" 0
for f in "${files[@]}" .env.pre-sp12 .env.identity.pre-sp12 .env.identity-db.pre-sp12 .env.problem.pre-sp12 .env.submission.pre-sp12; do
    check "$f is mode 600" "$(stat -c %a "$work/$f")" 600
done
check "no backup of the example" "$(ls "$work"/.env.example.pre-sp12 2>/dev/null | wc -l)" 0
check "no backup of an sp10 backup" "$(ls "$work"/.env.pre-sp10.pre-sp12 2>/dev/null | wc -l)" 0
check "the example is untouched" "$(cat "$work/.env.example")" "EXAMPLE=do-not-copy"
secrets=(judge-token-secret rootuser-value rootpass-value identity-db-secret jwt-private-secret google-secret-value
    problem-db-secret submission-db-secret "$gpw" "$pgpw")
args=(); for s in "${secrets[@]}"; do args+=(-e "$s"); done
check "no secret is printed" "$(printf '%s\n%s\n' "$out1" "$out2" | grep -cF "${args[@]}" || true)" 0
check "variable names are printed" "$(grep -cE '^generated (GRAFANA_ADMIN_PASSWORD|PG_MONITOR_PASSWORD|JUDGE_MAX_QUEUE_DEPTH)$' <<< "$out1" || true)" 3

# compose renders with the migrated files (the :? guards are satisfied)
if command -v docker > /dev/null && docker compose version > /dev/null 2>&1; then
    check "docker compose config renders with the migrated files" \
        "$(docker compose --project-directory "$work" -f "$here/docker-compose.yml" config -q > /dev/null 2>&1 && echo ok)" ok
else
    echo "skip compose render (no docker compose)"
fi

out3=$("$work/migrations/sp12-env.sh" restore)
for f in "${files[@]}"; do
    check "restore gives back $f byte for byte" "$(cmp "$work/$f" "$work/orig/$f" && echo same)" same
done
check "restore prints no value" "$(printf '%s\n' "$out3" | grep -cF "${args[@]}" || true)" 0

# An existing cap is left, an empty one is filled; an expiration line that is missing is appended.
printf 'JUDGE_SERVER_TOKEN=t\n' > "$w2/.env"
printf 'POSTGRES_DB=identity\n' > "$w2/.env.identity"
printf 'JUDGE_MAX_QUEUE_DEPTH=300\n' > "$w2/.env.submission"
"$w2/migrations/sp12-env.sh" create > /dev/null
check "an existing JUDGE_MAX_QUEUE_DEPTH=300 is kept" "$(val JUDGE_MAX_QUEUE_DEPTH "$w2/.env.submission")" 300
check "a missing expiration line is added" "$(val JWT_ACCESS_TOKEN_EXPIRATION "$w2/.env.identity")" 900000
printf 'JUDGE_MAX_QUEUE_DEPTH=\n' > "$w2/.env.submission"
"$w2/migrations/sp12-env.sh" create > /dev/null
check "an empty JUDGE_MAX_QUEUE_DEPTH is filled with 200" "$(val JUDGE_MAX_QUEUE_DEPTH "$w2/.env.submission")" 200
exit "$fail"
