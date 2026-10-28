#!/bin/bash
# Step 1 of the nightly backup (CronJob backup, container dump): the three Postgres dumps and the row counts taken just before and
# just after each (backup/backup.sh does the same for compose; the drill accepts anything in [min, max] because the system keeps
# writing). Connects over TLS with the certificate of the identity `backup`, as the database owner: the password of each database
# is in the environment as <SERVICE>_POSTGRES_PASSWORD (a prefix of the Secret that service's pods use).
set -euo pipefail
umask 077
# shellcheck source=/dev/null
source /opt/oj/backup/lib.sh   # BACKUP_COUNT_TABLES, byte for byte backup/lib.sh
staging=/staging
mkdir -p "$staging/minio"
: > "$staging/counts.tsv"

conn() { # <service>: a libpq connection string, the password aside
  local up=${1^^}
  local user=${up}_POSTGRES_USER db=${up}_POSTGRES_DB
  echo "host=$1-db port=5432 dbname=${!db} user=${!user} sslmode=verify-full sslrootcert=/etc/oj/tls/ca.crt sslcert=/etc/oj/tls/tls.crt sslkey=/etc/oj/tls/tls.key"
}
run() { # <service> <command> [args...]: the command with that service's password and, as its last argument, its connection string
  local up=${1^^}; local pw=${up}_POSTGRES_PASSWORD
  local svc=$1; shift
  PGPASSWORD=${!pw} "$@" "$(conn "$svc")"
}
count() { run "$1" psql -At -c "select count(*) from $2"; }

# A pod's first seconds: the network policies that admit it are programmed on the node a moment after it starts, so a first
# connection can be refused. Wait for each database instead of failing the night.
wait_for() { # <service>
  for _ in $(seq 1 30); do
    pg_isready -q -h "$1-db" -p 5432 && return 0
    sleep 2
  done
  echo "$1-db does not answer" >&2; return 1
}

for svc in identity problem submission; do
  wait_for "$svc"
  tables=(); before=()
  for pair in $BACKUP_COUNT_TABLES; do
    [ "${pair%%:*}" = "$svc" ] || continue
    tables+=("${pair#*:}"); before+=("$(count "$svc" "${pair#*:}")")
  done
  echo "dump $svc-db"
  run "$svc" pg_dump -Fc -f "$staging/$svc.dump"
  for i in "${!tables[@]}"; do
    after=$(count "$svc" "${tables[$i]}"); b=${before[$i]}
    lo=$(( b < after ? b : after )); hi=$(( b > after ? b : after ))
    printf '%s\t%s\t%s\n' "${tables[$i]}" "$lo" "$hi" >> "$staging/counts.tsv"
  done
done
echo "dumps done"
