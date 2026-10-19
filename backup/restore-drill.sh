#!/usr/bin/env bash
# Restore the latest snapshot into throwaway postgres containers and compare row counts (SP9 T9).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"

BACKUP_REPO="${BACKUP_REPO:-/home/tuan/oj-backups/restic}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$HOME/.config/oj-backup/restic-password}"
RESTIC_IMAGE="restic/restic:0.17.3"
docker=(docker --context default)

[ -f "$RESTIC_PASSWORD_FILE" ] || { echo "Missing restic password file: $RESTIC_PASSWORD_FILE" >&2; exit 2; }
tmp="$(mktemp -d)"
containers=()
cleanup() {
  for c in "${containers[@]}"; do "${docker[@]}" rm -f "$c" >/dev/null 2>&1 || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT

# 1. Latest snapshot -> $tmp/restore
mkdir -p "$tmp/restore"
"${docker[@]}" run --rm --user "$(id -u):$(id -g)" \
  -v "$BACKUP_REPO":/repo:ro -v "$tmp/restore":/restore -v "$RESTIC_PASSWORD_FILE":/pw:ro \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/pw "$RESTIC_IMAGE" \
  restore latest --target /restore --include /data
data="$tmp/restore/data"
[ -f "$data/counts.tsv" ] || { echo "snapshot has no counts.tsv" >&2; exit 1; }

# 2. Restore each dump into an isolated postgres and count rows.
: > "$tmp/actual.tsv"
for svc in identity problem submission; do
  name="oj-drill-$svc-$RANDOM$RANDOM"
  containers+=("$name")
  "${docker[@]}" run -d --name "$name" --network none \
    -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=drill \
    -v "$data":/data:ro postgres:16 >/dev/null
  for _ in $(seq 1 60); do
    "${docker[@]}" exec "$name" pg_isready -q -h 127.0.0.1 -U postgres && break
    sleep 1
  done
  "${docker[@]}" exec "$name" pg_restore -U postgres -d drill --no-owner --no-privileges "/data/$svc.dump"
  for pair in $BACKUP_COUNT_TABLES; do
    [ "${pair%%:*}" = "$svc" ] || continue
    tbl="${pair#*:}"
    n="$("${docker[@]}" exec "$name" psql -At -U postgres drill -c "select count(*) from $tbl")"
    printf '%s\t%s\n' "$tbl" "$n" >> "$tmp/actual.tsv"
  done
done

# 3. Restored MinIO files.
printf 'minio_objects\t%s\n' "$(find "$data/minio" -type f | wc -l)" >> "$tmp/actual.tsv"

# 4. Compare (cleanup runs on exit, with compare's status).
compare_counts "$data/counts.tsv" "$tmp/actual.tsv"
