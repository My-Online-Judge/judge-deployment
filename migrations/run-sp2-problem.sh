#!/usr/bin/env bash
# Runs sp2-problem.sh in a one-shot postgres:16 container, with oj-db's credentials from .env and
# problem-db's from .env.problem. Arguments go to sp2-problem.sh (copy|verify), and FORCE=1 too. Run from anywhere.
#
# The defaults target the live stack. The rehearsal overrides where the databases are:
#   NETWORK (oj-net)   SRC_HOST (db)   DST_HOST (problem-db)
set -euo pipefail
cd "$(dirname "$0")/.."

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
# libpq connection-string quoting: wrap in single quotes, escape backslashes and single quotes.
q() { printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"; }

SRC="host=${SRC_HOST:-db} dbname=$(q "$(val DATABASE_NAME .env)") user=$(q "$(val DATABASE_USERNAME .env)") password=$(q "$(val DATABASE_PASSWORD .env)")"
DST="host=${DST_HOST:-problem-db} dbname=$(q "$(val POSTGRES_DB .env.problem)") user=$(q "$(val POSTGRES_USER .env.problem)") password=$(q "$(val POSTGRES_PASSWORD .env.problem)")"

exec docker run --rm --network "${NETWORK:-oj-net}" -e SRC="$SRC" -e DST="$DST" -e FORCE="${FORCE:-}" \
    -v "$PWD/migrations:/migrations:ro" postgres:16 bash /migrations/sp2-problem.sh "$@"
