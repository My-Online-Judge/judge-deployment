#!/usr/bin/env bash
# Sub-project 3b, runbook step 7: the final backup of oj-db before it is retired — pg_dump -Fc of the whole
# database, then pg_restore --list must read it back. It also holds the stale identity tables, password hashes
# included: owner-only, in the gitignored backups/ directory, never pushed. Never overwrites an existing backup.
#   DB_CONTAINER (oj-db)   BACKUP_DIR (backups)
set -euo pipefail
cd "$(dirname "$0")/.."
container=${DB_CONTAINER:-oj-db}
dir=${BACKUP_DIR:-backups}
mkdir -p "$dir"
chmod 700 "$dir"
file="$dir/oj-db-final-$(date +%Y%m%d).dump"
[ ! -e "$file" ] || { echo "$file exists; not overwriting it" >&2; exit 1; }
user=$(docker exec "$container" printenv POSTGRES_USER)
db=$(docker exec "$container" printenv POSTGRES_DB)
umask 077
docker exec "$container" pg_dump -U "$user" -d "$db" -Fc > "$file.partial"
mv "$file.partial" "$file"
tables=$(docker run --rm -v "$(cd "$dir" && pwd):/b:ro" postgres:16 pg_restore --list "/b/$(basename "$file")" \
    | grep -c 'TABLE DATA public ')
echo "wrote $file ($(du -h "$file" | cut -f1)); pg_restore reads it back — tables with data: $tables"
