#!/usr/bin/env bash
# Checks migrations/split-env-sp1b.sh on a throwaway copy. .env.identity and the .env backup both hold
# the token-signing key, so both must be readable by their owner only — whatever mode .env has.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/migrations"
cp "$here/split-env-sp1b.sh" "$work/migrations/"
cat > "$work/.env" <<'ENV'
SPRING_PROFILES_ACTIVE=prod
REDIS_HOST=redis
REDIS_PORT=6379
DATABASE_PASSWORD=oj-db-secret
JWT_SECRET_KEY=retired
JWT_ACCESS_TOKEN_EXPIRATION=86400000
JWT_REFRESH_TOKEN_EXPIRATION=259200000
JWT_RSA_PRIVATE_KEY=private-key
JWT_RSA_PUBLIC_KEY=public-key
APP_BASE_URL=http://localhost
GOOGLE_CLIENT_ID=client
GOOGLE_CLIENT_SECRET=google-secret
ENV
chmod 664 "$work/.env"   # what a hand-made .env usually gets

"$work/migrations/split-env-sp1b.sh" create >/dev/null
"$work/migrations/split-env-sp1b.sh" strip >/dev/null

fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $3, got $2"; fail=1; fi
}
check ".env.identity is owner-only" "$(stat -c %a "$work/.env.identity")" 600
check ".env.pre-sp1b is owner-only" "$(stat -c %a "$work/.env.pre-sp1b")" 600
check "no JWT/Google settings left in .env" "$(grep -cE '^(JWT_|GOOGLE_)' "$work/.env" || true)" 0
check ".env keeps its own settings" "$(grep -c '^DATABASE_PASSWORD=' "$work/.env")" 1
check "the private key moved to .env.identity" "$(grep -c '^JWT_RSA_PRIVATE_KEY=private-key$' "$work/.env.identity")" 1
exit "$fail"
