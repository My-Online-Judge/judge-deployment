#!/usr/bin/env bash
# Prints "<problem slug> <CURRENT bundle hash>" for every problem with a published test-case bundle.
# Sub-project 2a runbook: run it before deploying and again after the backfill — the two lists must be
# equal. Runs mc inside oj-minio with that container's own credentials; prints no secret. (The MinIO
# image has no grep or awk, so the text work happens here.) MinIO serves TLS since sub-project 10: mc verifies it
# against the CA of the minio subpath.
set -euo pipefail
container="${MINIO_CONTAINER:-oj-minio}"
mcx() {
  docker exec "$container" sh -c \
    'export SSL_CERT_FILE=/etc/oj/tls/ca.crt; mc alias set oj https://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc "$@"' sh "$@"
}
mcx find oj/test-cases --name CURRENT | while read -r path; do
  slug=${path#oj/test-cases/}
  slug=${slug%/CURRENT}
  case "$slug" in */*) continue ;; esac   # only <slug>/CURRENT pointers
  echo "$slug $(mcx cat "$path")"
done | sort
