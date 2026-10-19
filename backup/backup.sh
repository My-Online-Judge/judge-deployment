#!/usr/bin/env bash
# Nightly backup: three Postgres dumps + the test-case bucket + env files -> restic repo (SP9 T9).
# Credentials are read inside the containers; nothing secret is read or printed on the host.
set -euo pipefail
# Staging dumps hold password hashes: keep them owner-only.
umask 077
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy="$(dirname "$here")"
source "$here/lib.sh"

BACKUP_REPO="${BACKUP_REPO:-/home/tuan/oj-backups/restic}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$HOME/.config/oj-backup/restic-password}"
RESTIC_IMAGE="restic/restic:0.17.3"
staging="$here/staging"
docker=(docker --context default)

if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
  echo "Missing restic password file: $RESTIC_PASSWORD_FILE" >&2
  echo "Create it (and keep a copy somewhere else, without it the backups are unreadable):" >&2
  echo "  mkdir -p \"$(dirname "$RESTIC_PASSWORD_FILE")\" && (umask 077; openssl rand -base64 32 > \"$RESTIC_PASSWORD_FILE\")" >&2
  exit 2
fi
echo "WARNING: backup repo $BACKUP_REPO is on the same disk as the live data; copy it off-host too." >&2
mkdir -p "$BACKUP_REPO"

bucket="test-cases"
if [ -f "$deploy/.env" ]; then
  v="$(grep -E '^MINIO_BUCKET=' "$deploy/.env" | tail -n1 | cut -d= -f2- | tr -d '"' || true)"
  [ -n "$v" ] && bucket="$v"
fi

restic() {
  "${docker[@]}" run --rm --user "$(id -u):$(id -g)" \
    -v "$BACKUP_REPO":/repo -v "$staging":/data:ro -v "$deploy":/deploy:ro \
    -v "$RESTIC_PASSWORD_FILE":/pw:ro \
    -e HOME=/tmp -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/pw "$RESTIC_IMAGE" "$@"
}

rm -rf "$staging"; mkdir -p "$staging/minio"
trap 'rm -rf "$staging"' EXIT

# 1. Postgres dumps. Each table is counted just before and just after its service's dump; the drill accepts
#    anything in [min, max] because the live system keeps writing.
count() { # <svc> <table>
  "${docker[@]}" exec "oj-$1-db" sh -c "psql -At -U \"\$POSTGRES_USER\" \"\$POSTGRES_DB\" -c 'select count(*) from $2'"
}
: > "$staging/counts.tsv"
for svc in identity problem submission; do
  c="oj-$svc-db"
  tables=(); before=()
  for pair in $BACKUP_COUNT_TABLES; do
    [ "${pair%%:*}" = "$svc" ] || continue
    tables+=("${pair#*:}"); before+=("$(count "$svc" "${pair#*:}")")
  done
  echo "dump $c"
  "${docker[@]}" exec "$c" sh -c 'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' > "$staging/$svc.dump"
  for i in "${!tables[@]}"; do
    after="$(count "$svc" "${tables[$i]}")"; b="${before[$i]}"
    lo=$(( b < after ? b : after )); hi=$(( b > after ? b : after ))
    printf '%s\t%s\t%s\n' "${tables[$i]}" "$lo" "$hi" >> "$staging/counts.tsv"
  done
done

# 2. Test-case bucket, mirrored inside oj-minio with an alias built from its own root credentials.
echo "mirror bucket $bucket"
"${docker[@]}" exec oj-minio sh -c 'rm -rf /tmp/oj-backup && mkdir -p /tmp/oj-backup/minio'
"${docker[@]}" exec -e BUCKET="$bucket" oj-minio sh -c \
  'MC_HOST_local="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@localhost:9000" mc mirror --overwrite "local/$BUCKET" /tmp/oj-backup/minio'
"${docker[@]}" cp oj-minio:/tmp/oj-backup/minio/. "$staging/minio/"
"${docker[@]}" exec oj-minio rm -rf /tmp/oj-backup

# 3. Bucket object count (exact).
n="$(find "$staging/minio" -type f | wc -l)"
printf 'minio_objects\t%s\t%s\n' "$n" "$n" >> "$staging/counts.tsv"

# 4. restic snapshot: staging, env files, pki/out, backups/.
[ -f "$BACKUP_REPO/config" ] || restic init
paths=(/data)
# NOTE: .env* files are found only under this script's own checkout; running from a worktree backs up none.
for f in "$deploy"/.env*; do
  [ -f "$f" ] || continue
  case "$f" in *.example) continue;; esac
  paths+=("/deploy/$(basename "$f")")
done
[ -d "$deploy/pki/out" ] && paths+=(/deploy/pki/out)
[ -d "$deploy/backups" ] && paths+=(/deploy/backups)
restic backup --host oj "${paths[@]}"

# 5. Retention.
restic forget --host oj --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# 6. Staging removed by the EXIT trap.
echo "backup done"
