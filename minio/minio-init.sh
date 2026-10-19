#!/bin/bash
# minio-init (sub-project 10, task 11): one-shot, once MinIO is healthy. With the root account it makes sure of the
# test-case bucket, the policies oj-problem-rw and oj-worker-ro (minio/policies, ${BUCKET} replaced by the bucket name)
# and the users $MINIO_PROBLEM_ACCESS_KEY and $MINIO_WORKER_ACCESS_KEY, each with its own policy. Every step is
# idempotent and leaves the bucket's objects alone, so it runs on every `up`: an existing bucket is kept, a policy is
# rewritten in place (its attachments stay), a user's secret is set to the env value again (its policies stay).
# MinIO is verified against the CA (SSL_CERT_FILE) under the name minio. Prints names, never a secret.
set -euo pipefail
: "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}" "${MINIO_BUCKET:?}" \
  "${MINIO_PROBLEM_ACCESS_KEY:?}" "${MINIO_PROBLEM_SECRET_KEY:?}" "${MINIO_WORKER_ACCESS_KEY:?}" "${MINIO_WORKER_SECRET_KEY:?}"
here=$(cd "$(dirname "$0")" && pwd)

policy() { # <name> <file>: creates or rewrites the policy from policies/<file>
  local json
  json=$(<"$here/policies/$2")
  # The image has no sed: bash replaces the placeholder.
  printf '%s\n' "${json//'${BUCKET}'/$MINIO_BUCKET}" > "/tmp/$2"
  mc admin policy create oj "$1" "/tmp/$2"
}

attach() { # <policy> <user>: attaches the policy; a policy that is already attached counts as done
  local out
  if out=$(mc admin policy attach oj "$1" --user "$2" 2>&1); then echo "$out"; return; fi
  case $out in
    *already*) echo "policy $1 is already attached to $2" ;;
    *) echo "$out" >&2; return 1 ;;
  esac
}

mc alias set oj https://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing "oj/$MINIO_BUCKET"
policy oj-problem-rw problem-rw.json
policy oj-worker-ro worker-ro.json
mc admin user add oj "$MINIO_PROBLEM_ACCESS_KEY" "$MINIO_PROBLEM_SECRET_KEY"
mc admin user add oj "$MINIO_WORKER_ACCESS_KEY" "$MINIO_WORKER_SECRET_KEY"
attach oj-problem-rw "$MINIO_PROBLEM_ACCESS_KEY"
attach oj-worker-ro "$MINIO_WORKER_ACCESS_KEY"
