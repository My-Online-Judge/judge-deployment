#!/usr/bin/env bash
# Sub-project 12: lists the identity accounts that would stop identity-service's Flyway V6. V6 makes usernames and
# emails unique case-insensitively, and Google ids unique, among live accounts (status <> 2, soft-deleted rows aside),
# and refuses to migrate while any are shared. Resolve each one (soft-delete, rename or unlink an account), then run this
# again before deploying V6.
# Read-only (the session is read-only). Runs psql over the Unix socket inside ${IDENTITY_DB_CONTAINER:-oj-identity-db},
# with that container's own POSTGRES_USER and POSTGRES_DB, so it needs no credentials here.
# Prints one line per duplicate, "username <lowercased> <count> <ids…>", "email <lowercased> <count> <ids…>" or
# "google_id <id> <count> <ids…>", and exits 1; or prints "no duplicates" and exits 0. Exits 2 if the query fails.
set -euo pipefail
container=${IDENTITY_DB_CONTAINER:-oj-identity-db}
docker=(docker --context default)

sql="SET default_transaction_read_only = on;
SELECT kind || ' ' || k || ' ' || count(*) || ' ' || string_agg(id::text, ' ' ORDER BY id::text)
FROM (SELECT 'username' AS kind, lower(username) AS k, id FROM public.t_users WHERE status <> 2 AND username IS NOT NULL
      UNION ALL
      SELECT 'email', lower(email), id FROM public.t_users WHERE status <> 2 AND email IS NOT NULL
      UNION ALL
      SELECT 'google_id', google_id, id FROM public.t_users WHERE status <> 2 AND google_id IS NOT NULL) d
GROUP BY kind, k HAVING count(*) > 1
ORDER BY kind, k;"

if ! out=$(printf '%s\n' "$sql" | "${docker[@]}" exec -i "$container" \
    sh -c 'exec psql -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'); then
  echo "sp12-dupes: the query in $container failed" >&2
  exit 2
fi
if [ -n "$out" ]; then
  printf '%s\n' "$out"
  exit 1
fi
echo "no duplicates"
