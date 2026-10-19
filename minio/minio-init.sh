#!/bin/bash
# minio-init (sub-project 10, task 11): one-shot, once MinIO is healthy. With the root account it makes sure of the
# test-case bucket, the policies oj-problem-rw and oj-worker-ro (minio/policies, ${BUCKET} replaced by the bucket name)
# and the users $MINIO_PROBLEM_ACCESS_KEY and $MINIO_WORKER_ACCESS_KEY, each with its own policy. Every step is
# idempotent and leaves the bucket's objects alone, so it runs on every `up`: an existing bucket is kept, a policy is
# rewritten in place (its attachments stay), a user's secret is set to the env value again (its policies stay).
# MinIO is verified against the CA (SSL_CERT_FILE) under the name minio. Prints names, never a secret, and no secret is
# ever a command-line argument: mc reads the root account from MC_HOST_oj and each user's secret from stdin.
set -euo pipefail
: "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}" "${MINIO_BUCKET:?}" \
  "${MINIO_PROBLEM_ACCESS_KEY:?}" "${MINIO_PROBLEM_SECRET_KEY:?}" "${MINIO_WORKER_ACCESS_KEY:?}" "${MINIO_WORKER_SECRET_KEY:?}"
die() { echo "minio-init: $*" >&2; exit 1; }
# One user for both services would hold both policies (the worker could write); a service key named like the root
# user would be the root account.
[[ $MINIO_PROBLEM_ACCESS_KEY != "$MINIO_WORKER_ACCESS_KEY" ]] || die "MINIO_PROBLEM_ACCESS_KEY and MINIO_WORKER_ACCESS_KEY must differ"
for v in MINIO_PROBLEM_ACCESS_KEY MINIO_WORKER_ACCESS_KEY; do
  [[ ${!v} != "$MINIO_ROOT_USER" ]] || die "$v must not equal MINIO_ROOT_USER"
done
# S3 bucket naming: 3-63 characters of a-z, 0-9, '.' and '-', starting and ending with a letter or digit.
[[ $MINIO_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
  || die "MINIO_BUCKET is not a valid bucket name (3-63 of a-z 0-9 . -, starting and ending with a letter or digit)"
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

policy() { # <name> <file>: creates or rewrites the policy from policies/<file>
  local json placeholder='${BUCKET}'
  json=$(<"$here/policies/$2")
  # The image has no sed: bash replaces the placeholder (the replacement quoted, so no character in it is special).
  printf '%s\n' "${json//"$placeholder"/"$MINIO_BUCKET"}" > "$tmp/$2"
  mc admin policy create oj "$1" "$tmp/$2"
}

user() { # <access key> <secret key>: creates the user or sets its secret again; mc reads the secret from stdin
  printf '%s\n' "$2" | mc admin user add oj "$1"
}

attach() { # <policy> <user>: attaches the policy; a policy that is already attached counts as done
  local out
  if out=$(mc admin policy attach oj "$1" --user "$2" 2>&1); then echo "$out"; return; fi
  # The server's two answers for it. This image's mc already turns the first (XMinioAdminPolicyChangeAlreadyApplied)
  # into success; an mc that does not prints the server's message.
  case $out in
    *"policy change is already in effect"* | *"policy is already attached"*) echo "policy $1 is already attached to $2" ;;
    *) echo "$out" >&2; return 1 ;;
  esac
}

# The root account as mc's host alias, from the environment (as backup/backup.sh does); the URL needs URL-safe values.
export MC_HOST_oj="https://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@minio:9000"
mc mb --ignore-existing "oj/$MINIO_BUCKET"
policy oj-problem-rw problem-rw.json
policy oj-worker-ro worker-ro.json
user "$MINIO_PROBLEM_ACCESS_KEY" "$MINIO_PROBLEM_SECRET_KEY"
user "$MINIO_WORKER_ACCESS_KEY" "$MINIO_WORKER_SECRET_KEY"
attach oj-problem-rw "$MINIO_PROBLEM_ACCESS_KEY"
attach oj-worker-ro "$MINIO_WORKER_ACCESS_KEY"
