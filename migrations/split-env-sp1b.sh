#!/usr/bin/env bash
# Moves identity's secrets out of .env into .env.identity (spec S6), in two steps of the runbook:
#   create  step 1 — write .env.identity: identity-db credentials (a fresh random password) plus a COPY
#           of the JWT signing keys, token lifetimes and Google OAuth settings. The same RSA key pair is
#           kept, so every token issued before the cutover stays valid. .env is not touched yet: the old
#           judge-api keeps issuing tokens until the cutover.
#   strip   step 4 — remove those settings, and the HS256 JWT_SECRET_KEY retired in 1a, from .env
#           (backup: .env.pre-sp1b), right before the new judge-api is created, so its container
#           environment no longer carries them.
set -euo pipefail
cd "$(dirname "$0")/.."
MOVED='^(JWT_RSA_PRIVATE_KEY|JWT_RSA_PUBLIC_KEY|JWT_ACCESS_TOKEN_EXPIRATION|JWT_REFRESH_TOKEN_EXPIRATION|GOOGLE_[A-Z_]+|APP_BASE_URL|COOKIE_SECURE)='
RETIRED='^JWT_SECRET_KEY='

case "${1:-}" in
    create)
        [ ! -e .env.identity ] || { echo ".env.identity already exists; not overwriting it" >&2; exit 1; }
        password=$(openssl rand -hex 24)
        umask 077
        {
            echo "# identity-db"
            echo "POSTGRES_DB=identity"
            echo "POSTGRES_USER=identity"
            echo "POSTGRES_PASSWORD=$password"
            echo
            echo "# identity-service (the database settings must match the three above)"
            echo "DATABASE_URL=jdbc:postgresql://identity-db:5432/identity"
            echo "DATABASE_USERNAME=identity"
            echo "DATABASE_PASSWORD=$password"
            grep -E '^(SPRING_PROFILES_ACTIVE|REDIS_HOST|REDIS_PORT)=' .env
            echo
            echo "# moved from .env: token signing, token lifetimes, Google OAuth"
            grep -E "$MOVED" .env
        } > .env.identity
        echo "wrote .env.identity ($(grep -cE "$MOVED" .env.identity) settings copied from .env)"
        ;;
    strip)
        [ -e .env.identity ] || { echo "run '$0 create' first" >&2; exit 1; }
        cp -p .env .env.pre-sp1b
        sed -i -E -e "/$MOVED/d" -e "/$RETIRED/d" .env
        echo "removed $(grep -cE "$MOVED|$RETIRED" .env.pre-sp1b) settings from .env (backup: .env.pre-sp1b)"
        ;;
    *)
        echo "usage: $0 create|strip" >&2
        exit 2
        ;;
esac
