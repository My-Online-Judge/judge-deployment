#!/usr/bin/env bash
# Sub-project 12: the read-only role the postgres-exporters log in with. In each database container
# (${PG_CONTAINERS:-oj-identity-db oj-problem-db oj-submission-db}) it creates the role oj_monitor (LOGIN) if absent, sets
# its password to PG_MONITOR_PASSWORD from .env (${ENV_FILE:-.env}; migrations/sp12-env.sh generates it) and grants it
# pg_monitor. Idempotent: run it again after the password changes. Over the Unix socket inside each container (local
# trust), so it needs no client certificate. The SQL, password included, goes through stdin, never a command line.
# Prints "ok <container>" per database, never the password.
set -euo pipefail
cd "$(dirname "$0")/.."
env_file=${ENV_FILE:-.env}
docker=(docker --context default)

[ -f "$env_file" ] || { echo "sp12-pg-monitor: no $env_file" >&2; exit 1; }
pw=$(grep -E '^PG_MONITOR_PASSWORD=' "$env_file" | tail -n 1 | cut -d= -f2- || true)
# compose drops one pair of surrounding quotes from a .env value; do the same
case $pw in \"*\") pw=${pw#\"}; pw=${pw%\"} ;; \'*\') pw=${pw#\'}; pw=${pw%\'} ;; esac
[ -n "$pw" ] || { echo "sp12-pg-monitor: PG_MONITOR_PASSWORD is missing or empty in $env_file (run migrations/sp12-env.sh create)" >&2; exit 1; }

# A string literal: every ' doubled (standard_conforming_strings is on, so a backslash is an ordinary character).
literal=${pw//\'/\'\'}
sql="SET client_min_messages = warning;
DO \$\$BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'oj_monitor') THEN CREATE ROLE oj_monitor LOGIN; END IF;
END\$\$;
ALTER ROLE oj_monitor PASSWORD '$literal';
GRANT pg_monitor TO oj_monitor;"

for c in ${PG_CONTAINERS:-oj-identity-db oj-problem-db oj-submission-db}; do
  if printf '%s\n' "$sql" | "${docker[@]}" exec -i "$c" \
      sh -c 'exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null; then
    echo "ok $c"
  else
    echo "sp12-pg-monitor: $c failed" >&2; exit 1
  fi
done
