#!/usr/bin/env bash
# Sub-project 3b, two steps of the runbook:
#   create  step 1 — write .env.submission: submission-db credentials (a fresh random password) and
#           submission-service's connection to them, read only by submission-db and submission-service.
#           Owner-only. An existing file is left as it is.
#   strip   step 7, after oj-db is retired — remove oj-db's DATABASE_* settings from .env (backup: .env.pre-sp3b,
#           owner-only), so no container is handed credentials for a database that is gone.
# Prints names, never values.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -e .env ] || { echo "no .env here" >&2; exit 1; }
ORPHANED='^(DATABASE_URL|DATABASE_USERNAME|DATABASE_PASSWORD|DATABASE_NAME)='

case "${1:-}" in
    create)
        if [ -e .env.submission ]; then
            echo ".env.submission exists; left as it is"
            exit 0
        fi
        password=$(openssl rand -hex 24)
        profile=$(grep -E '^SPRING_PROFILES_ACTIVE=' .env | tail -n 1 | cut -d= -f2-)
        umask 077
        {
            echo "# submission-db"
            echo "POSTGRES_DB=submission"
            echo "POSTGRES_USER=submission"
            echo "POSTGRES_PASSWORD=$password"
            echo
            echo "# submission-service (the database settings must match the three above)"
            echo "DATABASE_URL=jdbc:postgresql://submission-db:5432/submission"
            echo "DATABASE_USERNAME=submission"
            echo "DATABASE_PASSWORD=$password"
            echo "SPRING_PROFILES_ACTIVE=${profile:-prod}"
        } > .env.submission
        echo "wrote .env.submission (submission-db credentials, generated password)"
        ;;
    strip)
        if ! grep -qE "$ORPHANED" .env; then
            echo "no oj-db settings left in .env"
            exit 0
        fi
        # The backup still holds oj-db's password: owner-only, whatever mode .env has.
        install -m 600 .env .env.pre-sp3b
        sed -i -E "/$ORPHANED/d" .env
        echo "removed $(grep -cE "$ORPHANED" .env.pre-sp3b) oj-db settings from .env (backup: .env.pre-sp3b)"
        ;;
    *)
        echo "usage: $0 create|strip" >&2
        exit 2
        ;;
esac
