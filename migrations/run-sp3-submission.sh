#!/usr/bin/env bash
# Runs sp3-submission.sh in a one-shot postgres:16 container, with oj-db's credentials from .env and
# submission-db's from .env.submission. Arguments go to sp3-submission.sh (copy|verify), and FORCE=1 too.
#
# The defaults target the live stack. The rehearsal overrides where the databases are:
#   NETWORK (oj-net)   SRC_HOST (db)   DST_HOST (submission-db)
set -euo pipefail
cd "$(dirname "$0")/.."

val() { grep -E "^$1=" "$2" | tail -n 1 | cut -d= -f2-; }
# libpq connection-string quoting: wrap in single quotes, escape backslashes and single quotes.
q() { printf "'%s'" "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"; }

SRC="host=${SRC_HOST:-db} dbname=$(q "$(val DATABASE_NAME .env)") user=$(q "$(val DATABASE_USERNAME .env)") password=$(q "$(val DATABASE_PASSWORD .env)")"
DST="host=${DST_HOST:-submission-db} dbname=$(q "$(val POSTGRES_DB .env.submission)") user=$(q "$(val POSTGRES_USER .env.submission)") password=$(q "$(val POSTGRES_PASSWORD .env.submission)")"

exec docker run --rm --network "${NETWORK:-oj-net}" -e SRC="$SRC" -e DST="$DST" -e FORCE="${FORCE:-}" \
    -v "$PWD/migrations:/migrations:ro" postgres:16 bash /migrations/sp3-submission.sh "$@"
