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
# A repository is only created when RESTIC_INIT_IF_MISSING is set (k3d and CI, whose claim starts empty). On the server it is made
# once by hand (README), so a mistyped RESTIC_REPOSITORY fails the night instead of starting an empty repository that this job and
# the drill would both accept while the history sits somewhere else.
if ! restic cat config > /dev/null 2>&1; then
  if [ -n "${RESTIC_INIT_IF_MISSING:-}" ]; then
    restic init
  else
    echo "no restic repository at $RESTIC_REPOSITORY (wrong address or password, or never created): run restic init once, see k3s/README.md" >&2
    exit 3
  fi
fi
restic backup --host oj /staging
restic forget --host oj --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
echo "backup done"
