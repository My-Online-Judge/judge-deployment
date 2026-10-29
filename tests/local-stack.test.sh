#!/usr/bin/env bash
# scripts/local-stack.sh: the .env files it writes (every secret generated, nothing readable by others, the identity
# database password and the JWT key pair consistent, a second run changes nothing) and docker-compose.local.yml (only
# MinIO's S3 port stays published). Works on a copy of the .example files in a temporary directory; prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
script=scripts/local-stack.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

envfiles=(.env .env.identity-db .env.identity .env.problem .env.submission)
for f in .env*.example; do cp "$f" "$tmp/$f"; done
all_env() { for f in "${envfiles[@]}"; do cat "$tmp/$f"; done; }
OJ_DEPLOY_DIR=$tmp bash "$script" env > "$tmp/first.log"
missing=$(for f in "${envfiles[@]}"; do [[ -f $tmp/$f ]] || echo "$f"; done)
if [[ -z $missing ]]; then ok "env writes the five .env files"; else bad "env did not write: $missing"; fi

modes=$(for f in "${envfiles[@]}"; do stat -c '%a' "$tmp/$f" 2> /dev/null || stat -f '%Lp' "$tmp/$f"; done | sort -u)
if [[ $modes == 600 ]]; then ok "every .env file is mode 600"; else bad "modes of the .env files: $modes"; fi

placeholders=$(for f in "${envfiles[@]}"; do grep -lE '=(change-me[a-z-]*|minioadmin123)$' "$tmp/$f" || true; done)
if [[ -z $placeholders ]]; then ok "no placeholder password or token is left"; else bad "placeholders left in: $placeholders"; fi

value() { grep "^$2=" "$tmp/$1" | cut -d= -f2-; }
pw=$(value .env RESTIC_PASSWORD)
if [[ $(value .env RESTIC_REPOSITORY) == /repo && ${#pw} -ge 32 ]]; then ok "the k3d backup repository is the claim /repo, with a generated password"
else bad "RESTIC_REPOSITORY / RESTIC_PASSWORD of .env: $(value .env RESTIC_REPOSITORY) (${#pw} chars)"; fi
if [[ $(value .env.identity POSTGRES_PASSWORD) == "$(value .env.identity DATABASE_PASSWORD)" \
  && $(value .env.identity POSTGRES_PASSWORD) == "$(value .env.identity-db POSTGRES_PASSWORD)" ]]; then
  ok "identity-db and identity-service share one password"
else bad "the identity database password differs between POSTGRES_PASSWORD and DATABASE_PASSWORD of .env.identity, or .env.identity-db"; fi
if [[ $(value .env.problem POSTGRES_PASSWORD) != "$(value .env.submission POSTGRES_PASSWORD)" \
  && $(value .env.problem POSTGRES_PASSWORD) != "$(value .env.identity POSTGRES_PASSWORD)" ]]; then
  ok "each database has its own password"
else bad "two databases share a password"; fi

printf '%s' "$(value .env.identity JWT_RSA_PRIVATE_KEY)" | base64 -d > "$tmp/k.pem"
printf '%s' "$(value .env.identity JWT_RSA_PUBLIC_KEY)" | base64 -d > "$tmp/p.pem"
if [[ $(openssl pkey -in "$tmp/k.pem" -pubout) == "$(cat "$tmp/p.pem")" ]]; then ok "the JWT public key belongs to the private key"
else bad "the JWT key pair does not match"; fi

before=$(all_env | shasum)
OJ_DEPLOY_DIR=$tmp bash "$script" env > "$tmp/second.log"
after=$(all_env | shasum)
if [[ $before == "$after" && $(grep -c '^kept ' "$tmp/second.log") == 5 ]]; then ok "a second run keeps all five files unchanged"
else bad "a second run changed a file: $(cat "$tmp/second.log")"; fi

if bash "$script" nonsense > /dev/null 2>&1; then bad "an unknown command exits 0"; else
  [[ $? == 2 ]] && ok "an unknown command prints the usage and exits 2" || bad "an unknown command exits with another code"; fi

# The local override: the stack's MinIO publishes the S3 API on loopback and no console.
ports=$(docker compose --project-directory "$tmp" -f "$PWD/docker-compose.yml" -f "$PWD/docker-compose.mock.yml" \
  -f "$PWD/docker-compose.local.yml" config --format json | python3 -c '
import json, sys
print(sorted((p["host_ip"], int(p["published"])) for p in json.load(sys.stdin)["services"]["minio"]["ports"]))')
if [[ $ports == "[('127.0.0.1', 9000)]" ]]; then ok "with docker-compose.local.yml MinIO publishes only 127.0.0.1:9000"
else bad "MinIO ports with the local override: $ports"; fi
# the smoke test can aim at the K3s stack: OJ_SMOKE_BASE (default https://localhost) and OJ_SMOKE_CA (default compose's CA)
if grep -q 'local base=${OJ_SMOKE_BASE:-https://localhost}' scripts/local-stack.sh && grep -q 'ca=${OJ_SMOKE_CA:-pki/out/ca/ca.crt}' scripts/local-stack.sh; then ok "smoke honours OJ_SMOKE_BASE and OJ_SMOKE_CA, with compose's address and CA as the defaults"
else bad "smoke does not take OJ_SMOKE_BASE / OJ_SMOKE_CA"; fi
exit $fail
