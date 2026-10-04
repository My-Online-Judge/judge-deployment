#!/usr/bin/env bash
# Sub-project 2b, runbook step 1: the settings problem-service needs, generated once.
#   .env.problem      problem-db credentials (a fresh random password) and problem-service's connection to
#                     it; read only by problem-db and problem-service. Owner-only.
#   PROBLEM_RPC_TOKEN appended to .env: the service token judge-api sends on every gRPC call and
#                     problem-service checks (64 hex characters).
# Idempotent: an existing .env.problem or token is left as it is. Prints names, never values.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -e .env ] || { echo "no .env here" >&2; exit 1; }

if [ -e .env.problem ]; then
    echo ".env.problem exists; left as it is"
else
    password=$(openssl rand -hex 24)
    profile=$(grep -E '^SPRING_PROFILES_ACTIVE=' .env | tail -n 1 | cut -d= -f2-)
    umask 077
    {
        echo "# problem-db"
        echo "POSTGRES_DB=problem"
        echo "POSTGRES_USER=problem"
        echo "POSTGRES_PASSWORD=$password"
        echo
        echo "# problem-service (the database settings must match the three above)"
        echo "DATABASE_URL=jdbc:postgresql://problem-db:5432/problem"
        echo "DATABASE_USERNAME=problem"
        echo "DATABASE_PASSWORD=$password"
        echo "SPRING_PROFILES_ACTIVE=${profile:-prod}"
    } > .env.problem
    echo "wrote .env.problem (problem-db credentials, generated password)"
fi

if grep -qE '^PROBLEM_RPC_TOKEN=' .env; then
    echo "PROBLEM_RPC_TOKEN already in .env; left as it is"
else
    printf '\n# Service token for problem-service'"'"'s internal gRPC API (sub-project 2b)\nPROBLEM_RPC_TOKEN=%s\n' \
        "$(openssl rand -hex 32)" >> .env
    echo "added PROBLEM_RPC_TOKEN to .env"
fi
