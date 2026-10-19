#!/usr/bin/env bash
# Sub-project 10, the environment step of the runbook (run in the judge-deployment directory):
#   create   idempotent. Backs up every .env* to <file>.pre-sp10 (owner-only, once), then
#            - writes .env.identity-db (owner-only): identity-db's three POSTGRES_* lines, so the database container
#              no longer receives identity's JWT and Google secrets;
#            - .env: one MinIO account per service (MINIO_PROBLEM_* / MINIO_WORKER_*, generated when absent), a 48-char
#              JUDGE_SERVER_TOKEN (replaced unless it already is), and drops the keys compose no longer reads
#              (PROBLEM_RPC_TOKEN, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_ENDPOINT, JUDGE_SERVER_URL);
#            - .env.identity: APP_BASE_URL and GOOGLE_REDIRECT_URI move to https://<OJ_PUBLIC_HOST from .env, else
#              localhost>, paths kept. Register the new redirect URI in the Google console.
#   restore  copies every <file>.pre-sp10 back over its file (.env.identity-db is not restored: it had no original).
# Prints names, never values.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -e .env ] || { echo "no .env here" >&2; exit 1; }
RETIRED=(PROBLEM_RPC_TOKEN MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_ENDPOINT JUDGE_SERVER_URL)

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2- || true; }
# set_key FILE NAME VALUE — replace the line or append it (values here are hex or URLs without & or |).
set_key() {
    if grep -qE "^$2=" "$1"; then
        sed -i -E "s|^$2=.*|$2=$3|" "$1"
    else
        [ -z "$(tail -c1 "$1")" ] || echo >> "$1"
        echo "$2=$3" >> "$1"
    fi
}
# ensure_key FILE NAME VALUE — only when absent or empty
ensure_key() {
    if [ -z "$(val "$2" "$1")" ]; then
        set_key "$1" "$2" "$3"
        echo "generated $2"
    fi
}

case "${1:-}" in
    create)
        umask 077
        [ -e .env.identity ] || { echo "no .env.identity here" >&2; exit 1; }
        for f in .env .env.*; do
            case "$f" in *.example | *.pre-sp* | .env.identity-db) continue ;; esac
            [ -f "$f" ] || continue
            if [ ! -e "$f.pre-sp10" ]; then install -m 600 "$f" "$f.pre-sp10"; echo "backed up $f"; fi
        done

        {
            for k in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD; do
                [ -n "$(val $k .env.identity)" ] || { echo ".env.identity has no $k" >&2; exit 1; }
                echo "$k=$(val $k .env.identity)"
            done
        } > .env.identity-db.new
        mv .env.identity-db.new .env.identity-db
        chmod 600 .env.identity-db
        echo "wrote .env.identity-db (POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD)"

        ensure_key .env MINIO_PROBLEM_ACCESS_KEY oj-problem
        ensure_key .env MINIO_WORKER_ACCESS_KEY oj-worker
        ensure_key .env MINIO_PROBLEM_SECRET_KEY "$(openssl rand -hex 24)"
        ensure_key .env MINIO_WORKER_SECRET_KEY "$(openssl rand -hex 24)"
        if ! val JUDGE_SERVER_TOKEN .env | grep -qE '^.{48}$'; then
            set_key .env JUDGE_SERVER_TOKEN "$(openssl rand -hex 24)"
            echo "generated JUDGE_SERVER_TOKEN"
        fi
        for k in "${RETIRED[@]}"; do
            if grep -qE "^$k=" .env; then sed -i -E "/^$k=/d" .env; echo "removed $k"; fi
        done

        host=$(val OJ_PUBLIC_HOST .env)
        host=${host:-localhost}
        [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "OJ_PUBLIC_HOST is not a host name" >&2; exit 1; }
        for k in APP_BASE_URL GOOGLE_REDIRECT_URI; do
            if grep -qE "^$k=https?://[^/]" .env.identity; then
                sed -i -E "s|^($k=)https?://[^/]*|\1https://$host|" .env.identity
                echo "set $k to https://<public host>"
            elif grep -qE "^(export[[:space:]]+)?$k=" .env.identity; then
                echo "left $k unchanged (unexpected format)"
            fi
        done
        chmod 600 .env .env.identity
        ;;
    restore)
        for b in .env*.pre-sp10; do
            [ -f "$b" ] || continue
            install -m 600 "$b" "${b%.pre-sp10}"
            echo "restored ${b%.pre-sp10}"
        done
        ;;
    *)
        echo "usage: $0 create|restore" >&2
        exit 2
        ;;
esac
