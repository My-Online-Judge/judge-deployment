#!/usr/bin/env bash
# Runs sp1-identity.sh in a one-shot postgres:16 container, with oj-db's credentials from .env and
# identity-db's from .env.identity. Run from anywhere; it works in judge-deployment/.
#
# The defaults target the live stack. The rehearsal overrides where the databases are:
#   NETWORK (oj-net)   SRC_HOST (db)   DST_HOST (identity-db)
set -euo pipefail
cd "$(dirname "$0")/.."

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
# libpq connection-string quoting: wrap in single quotes, escape backslashes and single quotes.
q() { printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"; }

SRC="host=${SRC_HOST:-db} dbname=$(q "$(val DATABASE_NAME .env)") user=$(q "$(val DATABASE_USERNAME .env)") password=$(q "$(val DATABASE_PASSWORD .env)")"
DST="host=${DST_HOST:-identity-db} dbname=$(q "$(val POSTGRES_DB .env.identity)") user=$(q "$(val POSTGRES_USER .env.identity)") password=$(q "$(val POSTGRES_PASSWORD .env.identity)")"

exec docker run --rm --network "${NETWORK:-oj-net}" -e SRC="$SRC" -e DST="$DST" \
    -v "$PWD/migrations:/migrations:ro" postgres:16 bash /migrations/sp1-identity.sh
