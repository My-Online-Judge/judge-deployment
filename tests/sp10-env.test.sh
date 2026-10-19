#!/usr/bin/env bash
# Checks migrations/sp10-env.sh on fixture env files in a temp dir (never the real ones): create twice is idempotent,
# identity-db gets only its own three keys, MinIO gets one account per service, the sandbox token is 48 hex, the five
# retired keys are gone, the identity URLs move to https://<public host> with their paths, modes are 600, nothing
# secret is printed; restore gives back the original bytes.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/migrations" "$work/orig"
cp "$here/migrations/sp10-env.sh" "$work/migrations/"
cat > "$work/.env" <<'ENV'
SPRING_PROFILES_ACTIVE=prod
JUDGE_SERVER_TOKEN=old-short-token-value
PROBLEM_RPC_TOKEN=rpc-token-value
KAFKA_BROKERS=kafka:29092
MINIO_ROOT_USER=rootuser-value
MINIO_ROOT_PASSWORD=rootpass-value
MINIO_ENDPOINT=http://minio:9000
MINIO_ACCESS_KEY=legacy-access-value
MINIO_SECRET_KEY=legacy-secret-value
MINIO_BUCKET=oj-problems
JUDGE_SERVER_URL=http://sandbox:2358
OJ_PUBLIC_HOST=oj.example.test
ENV
cat > "$work/.env.identity" <<'ENV'
POSTGRES_DB=identity
POSTGRES_USER=identity
POSTGRES_PASSWORD=identity-db-secret
DATABASE_URL=jdbc:postgresql://identity-db:5432/identity
JWT_RSA_PRIVATE_KEY=jwt-private-secret
APP_BASE_URL=http://localhost
GOOGLE_CLIENT_SECRET=google-secret-value
GOOGLE_REDIRECT_URI=http://localhost:8000/api/v1/auth/outbound/google/callback
ENV
cat > "$work/.env.problem" <<'ENV'
POSTGRES_PASSWORD=problem-db-secret
ENV
chmod 664 "$work/.env" "$work/.env.identity"
chmod 640 "$work/.env.problem"
cp -p "$work"/.env "$work"/.env.identity "$work"/.env.problem "$work/orig/"

out1=$("$work/migrations/sp10-env.sh" create)
snap1=$(cd "$work" && md5sum .env .env.identity .env.identity-db .env.problem)
out2=$("$work/migrations/sp10-env.sh" create)
snap2=$(cd "$work" && md5sum .env .env.identity .env.identity-db .env.problem)

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $3, got $2"; fail=1; fi
}
check ".env.identity-db holds exactly the three POSTGRES keys" \
    "$(grep -o '^[A-Z_]*=' "$work/.env.identity-db" | tr -d '=' | sort | tr '\n' ' ')" "POSTGRES_DB POSTGRES_PASSWORD POSTGRES_USER "
check ".env.identity-db copies the values from .env.identity" \
    "$(val POSTGRES_DB "$work/.env.identity-db"),$(val POSTGRES_USER "$work/.env.identity-db"),$(val POSTGRES_PASSWORD "$work/.env.identity-db")" \
    "identity,identity,identity-db-secret"
check "problem access key is oj-problem" "$(val MINIO_PROBLEM_ACCESS_KEY "$work/.env")" oj-problem
check "worker access key is oj-worker" "$(val MINIO_WORKER_ACCESS_KEY "$work/.env")" oj-worker
for k in MINIO_PROBLEM_SECRET_KEY MINIO_WORKER_SECRET_KEY; do
    check "$k is 48 hex" "$(val $k "$work/.env" | grep -cE '^[0-9a-f]{48}$' || true)" 1
done
check "the two secrets differ" "$([ "$(val MINIO_PROBLEM_SECRET_KEY "$work/.env")" != "$(val MINIO_WORKER_SECRET_KEY "$work/.env")" ] && echo yes)" yes
check "JUDGE_SERVER_TOKEN is 48 hex" "$(val JUDGE_SERVER_TOKEN "$work/.env" | grep -cE '^[0-9a-f]{48}$' || true)" 1
check "a second create changes nothing (all files)" "$snap2" "$snap1"
for k in PROBLEM_RPC_TOKEN MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_ENDPOINT JUDGE_SERVER_URL; do
    check "$k is retired" "$(grep -c "^$k=" "$work/.env" || true)" 0
done
check "the rest of .env is kept" \
    "$(val KAFKA_BROKERS "$work/.env"),$(val MINIO_ROOT_USER "$work/.env"),$(val MINIO_BUCKET "$work/.env"),$(val OJ_PUBLIC_HOST "$work/.env")" \
    "kafka:29092,rootuser-value,oj-problems,oj.example.test"
check "APP_BASE_URL uses the public host" "$(val APP_BASE_URL "$work/.env.identity")" "https://oj.example.test"
check "GOOGLE_REDIRECT_URI keeps its path" "$(val GOOGLE_REDIRECT_URI "$work/.env.identity")" "https://oj.example.test/api/v1/auth/outbound/google/callback"
check ".env.identity keeps its other keys" "$(val JWT_RSA_PRIVATE_KEY "$work/.env.identity"),$(val DATABASE_URL "$work/.env.identity")" "jwt-private-secret,jdbc:postgresql://identity-db:5432/identity"
for f in .env .env.identity .env.identity-db .env.pre-sp10 .env.identity.pre-sp10 .env.problem.pre-sp10; do
    check "$f is mode 600" "$(stat -c %a "$work/$f")" 600
done
check "no backup of the file that did not exist" "$(ls "$work"/.env.identity-db.pre-sp10 2>/dev/null | wc -l)" 0
secrets=(old-short-token-value rpc-token-value rootuser-value rootpass-value legacy-access-value legacy-secret-value
    identity-db-secret jwt-private-secret google-secret-value problem-db-secret
    "$(val JUDGE_SERVER_TOKEN "$work/.env")" "$(val MINIO_PROBLEM_SECRET_KEY "$work/.env")" "$(val MINIO_WORKER_SECRET_KEY "$work/.env")")
args=(); for s in "${secrets[@]}"; do args+=(-e "$s"); done
check "no secret is printed" "$(printf '%s\n' "$out1" "$out2" | grep -cF "${args[@]}" || true)" 0

out3=$("$work/migrations/sp10-env.sh" restore)
for f in .env .env.identity .env.problem; do
    check "restore gives back $f byte for byte" "$(cmp "$work/$f" "$work/orig/$f" && echo same)" same
done
check "restore prints no value" "$(printf '%s\n' "$out3" | grep -cF "${args[@]}" || true)" 0
exit "$fail"
