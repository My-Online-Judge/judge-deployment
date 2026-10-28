#!/bin/sh
# Step 3 of the nightly backup (container restic): the staging directory into the restic repository, then the retention of
# backup/backup.sh. The repository is whatever the Secret `restic` says (RESTIC_REPOSITORY, RESTIC_PASSWORD and, for S3 or B2,
# their access keys): off the cluster's disk on the server. Without both it stops, so a night is never silently skipped.
set -eu
if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ]; then
  echo "RESTIC_REPOSITORY and RESTIC_PASSWORD are not set: put them in .env and run k3s/scripts/env-to-secrets.sh" >&2
  exit 2
fi
export HOME=/tmp RESTIC_CACHE_DIR=/tmp/restic-cache
# a repository that does not exist yet is made on the first night; a wrong password or an unreachable one fails the init as well
restic cat config > /dev/null 2>&1 || restic init
restic backup --host oj /staging
restic forget --host oj --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
echo "backup done"
