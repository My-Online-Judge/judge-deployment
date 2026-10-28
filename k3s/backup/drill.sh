#!/bin/bash
# The restore drill (CronJob restore-drill, container verify; the init container restic-restore has put the latest snapshot in
# /restore): backup/restore-drill.sh for pods. Each dump is restored into a throwaway Postgres inside this container (no network,
# no certificate, nothing of the live system) and the row counts are compared with the counts.tsv taken at backup time. Exit 0 and
# only PASS (or INFO) lines means the backup restores.
set -euo pipefail
# shellcheck source=/dev/null
source /opt/oj/backup/lib.sh
data=/restore/staging
[ -f "$data/counts.tsv" ] || { echo "snapshot has no counts.tsv" >&2; exit 1; }

snap=$(stat -c %Y "$data/counts.tsv")
echo "snapshot taken $(date -d "@$snap" '+%F %T')"
if [ $(( $(date +%s) - snap )) -gt $(( 36 * 3600 )) ]; then
  echo "FAIL snapshot is older than 36 hours" >&2; exit 1
fi

pgdata=/tmp/pgdata
initdb -D "$pgdata" -U postgres -A trust > /dev/null
pg_ctl -D "$pgdata" -o "-c listen_addresses='' -c unix_socket_directories=/tmp" -w -l /tmp/pg.log start > /dev/null
trap 'pg_ctl -D "$pgdata" -m immediate stop > /dev/null 2>&1 || true' EXIT

actual=/tmp/actual.tsv
: > "$actual"
for svc in identity problem submission; do
  createdb -h /tmp -U postgres "drill_$svc"
  pg_restore -h /tmp -U postgres -d "drill_$svc" --no-owner --no-privileges "$data/$svc.dump"
  for pair in $BACKUP_COUNT_TABLES; do
    [ "${pair%%:*}" = "$svc" ] || continue
    tbl=${pair#*:}
    printf '%s\t%s\n' "$tbl" "$(psql -h /tmp -At -U postgres "drill_$svc" -c "select count(*) from $tbl")" >> "$actual"
  done
done
printf 'minio_objects\t%s\n' "$(find "$data/minio" -type f | wc -l)" >> "$actual"

compare_counts "$data/counts.tsv" "$actual"
