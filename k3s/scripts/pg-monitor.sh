#!/usr/bin/env bash
# The read-only role the postgres-exporters log in with, in each of the three databases on K3s: migrations/sp12-pg-monitor.sh for
# pods. Creates oj_monitor (LOGIN) if absent, sets its password to the one in the Secret pg-monitor (k3s/scripts/env-to-secrets.sh
# makes it from PG_MONITOR_PASSWORD) and grants it pg_monitor. Idempotent: run it again after the password changes. The SQL goes
# through stdin over the Unix socket inside each pod (local trust), so the password is never on a command line. Prints
# "ok <pod>" per database, never the password. The role lives in the database's volume, so once per database, not per pod start.
set -euo pipefail
pw=$(kubectl -n oj get secret pg-monitor -o jsonpath='{.data.PG_MONITOR_PASSWORD}' | base64 -d)
[ -n "$pw" ] || { echo "pg-monitor.sh: the Secret pg-monitor has no PG_MONITOR_PASSWORD (run k3s/scripts/env-to-secrets.sh)" >&2; exit 1; }

# A string literal: every ' doubled (standard_conforming_strings is on, so a backslash is an ordinary character).
literal=${pw//\'/\'\'}
sql="SET client_min_messages = warning;
DO \$\$BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'oj_monitor') THEN CREATE ROLE oj_monitor LOGIN; END IF;
END\$\$;
ALTER ROLE oj_monitor PASSWORD '$literal';
GRANT pg_monitor TO oj_monitor;"

for pod in identity-db-0 problem-db-0 submission-db-0; do
  # the single quotes are deliberate: the variables expand inside the pod
  # shellcheck disable=SC2016
  if printf '%s\n' "$sql" | kubectl -n oj exec -i "$pod" -- \
      sh -c 'exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > /dev/null; then
    echo "ok $pod"
  else
    echo "pg-monitor.sh: $pod failed" >&2; exit 1
  fi
done
