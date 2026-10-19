#!/usr/bin/env bash
# MinIO least-privilege keys (sub-project 10, task 11): problem-service may read, write and delete test-case objects, the
# worker may only read them, and neither gets more than the test-case bucket. minio/minio-init.sh creates the policies
# from these files (${BUCKET} replaced) and attaches each to its own user. Prints descriptions, never a value.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { # check <description> <file> <jq expression that must print true>
  if [[ $(jq -r "$3" "$2" 2>/dev/null) == true ]]; then ok "$1"; else bad "$1"; fi
}

problem=minio/policies/problem-rw.json
worker=minio/policies/worker-ro.json
objects='"arn:aws:s3:::${BUCKET}/*"'
bucket='"arn:aws:s3:::${BUCKET}"'
# Every statement allows; the actions per resource, as {resource: sorted actions}.
by_resource='[.Statement[] | .Resource[] as $r | .Action[] | {r: $r, a: .}] | group_by(.r) | map({(.[0].r): (map(.a) | sort)}) | add'

check "problem-rw: every statement is Allow, nothing else" "$problem" '[.Statement[].Effect] | unique == ["Allow"]'
check "problem-rw: exactly the 5 actions (get, put, delete objects; list, locate the bucket)" "$problem" \
  '[.Statement[].Action[]] | sort == ["s3:DeleteObject", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject"]'
check "problem-rw: object actions on the bucket's objects, bucket actions on the bucket, no other resource" "$problem" \
  "$by_resource == {$objects: [\"s3:DeleteObject\", \"s3:GetObject\", \"s3:PutObject\"], $bucket: [\"s3:GetBucketLocation\", \"s3:ListBucket\"]}"

check "worker-ro: every statement is Allow, nothing else" "$worker" '[.Statement[].Effect] | unique == ["Allow"]'
check "worker-ro: exactly s3:GetObject, s3:ListBucket, s3:GetBucketLocation" "$worker" \
  '[.Statement[].Action[]] | sort == ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"]'
check "worker-ro: no Put or Delete action" "$worker" '[.Statement[].Action[] | select(test("Put|Delete"))] == []'
check "worker-ro: s3:GetObject on the bucket's objects, list and locate on the bucket, no other resource" "$worker" \
  "$by_resource == {$objects: [\"s3:GetObject\"], $bucket: [\"s3:GetBucketLocation\", \"s3:ListBucket\"]}"

# Each policy goes to its own user: a swapped attach would hand the worker write access.
if grep -qF 'attach oj-problem-rw "$MINIO_PROBLEM_ACCESS_KEY"' minio/minio-init.sh 2>/dev/null \
  && grep -qF 'attach oj-worker-ro "$MINIO_WORKER_ACCESS_KEY"' minio/minio-init.sh; then
  ok "minio-init.sh attaches oj-problem-rw to the problem key and oj-worker-ro to the worker key"
else bad "minio-init.sh attaches oj-problem-rw to the problem key and oj-worker-ro to the worker key"; fi

exit $fail
