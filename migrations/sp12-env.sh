#!/usr/bin/env bash
# Sub-project 12, the environment step of the runbook (run in the judge-deployment directory):
#   create   idempotent. Backs up every .env* to <file>.pre-sp12 (owner-only, once), then
#            - .env.identity: JWT_ACCESS_TOKEN_EXPIRATION=900000 (15-minute access tokens);
#            - .env: GRAFANA_ADMIN_PASSWORD and PG_MONITOR_PASSWORD, generated when absent (compose refuses to render
#              without them);
#            - .env.submission: JUDGE_MAX_QUEUE_DEPTH=200 when absent or empty (the code default is 500; an existing
#              value stays). Bench runs share these files and inherit the cap.
#            ALERT_TELEGRAM_* is optional and never generated.
#   restore  copies every <file>.pre-sp12 back over its file.
# Prints names, never values.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -e .env ] || { echo "no .env here" >&2; exit 1; }

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2- || true; }
# set_key FILE NAME VALUE — replace the line or append it (values here are hex or digits).
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
        [ -e .env.submission ] || { echo "no .env.submission here" >&2; exit 1; }
        for f in .env .env.*; do
            case "$f" in *.example | *.pre-sp*) continue ;; esac
            [ -f "$f" ] || continue
            if [ ! -e "$f.pre-sp12" ]; then install -m 600 "$f" "$f.pre-sp12"; echo "backed up $f"; fi
            chmod 600 "$f"
        done

        if [ "$(val JWT_ACCESS_TOKEN_EXPIRATION .env.identity)" != 900000 ]; then
            set_key .env.identity JWT_ACCESS_TOKEN_EXPIRATION 900000
            echo "set JWT_ACCESS_TOKEN_EXPIRATION"
        fi
        ensure_key .env GRAFANA_ADMIN_PASSWORD "$(openssl rand -hex 16)"
        ensure_key .env PG_MONITOR_PASSWORD "$(openssl rand -hex 24)"
        ensure_key .env.submission JUDGE_MAX_QUEUE_DEPTH 200
        ;;
    restore)
        for b in .env*.pre-sp12; do
            [ -f "$b" ] || continue
            install -m 600 "$b" "${b%.pre-sp12}"
            echo "restored ${b%.pre-sp12}"
        done
        ;;
    *)
        echo "usage: $0 create|restore" >&2
        exit 2
        ;;
esac
