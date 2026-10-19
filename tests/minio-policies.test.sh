#!/usr/bin/env bash
# MinIO least-privilege keys (sub-project 10, task 11): problem-service may read, write and delete test-case objects, the
# worker may only read them, and neither gets more than the test-case bucket. minio/minio-init.sh creates the policies
# from these files (${BUCKET} replaced) and attaches each to its own user; it runs here against a stub mc that records
# what it is given. Prints descriptions, never a value.
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
# s3:AbortMultipartUpload: minio-java uploads large objects in parts and aborts a failed upload (else its parts stay).
check "problem-rw: exactly the 6 actions (get, put, delete objects, abort an upload; list, locate the bucket)" "$problem" \
  '[.Statement[].Action[]] | sort == ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject"]'
check "problem-rw: object actions on the bucket's objects, bucket actions on the bucket, no other resource" "$problem" \
  "$by_resource == {$objects: [\"s3:AbortMultipartUpload\", \"s3:DeleteObject\", \"s3:GetObject\", \"s3:PutObject\"], $bucket: [\"s3:GetBucketLocation\", \"s3:ListBucket\"]}"

check "worker-ro: every statement is Allow, nothing else" "$worker" '[.Statement[].Effect] | unique == ["Allow"]'
check "worker-ro: exactly s3:GetObject, s3:ListBucket, s3:GetBucketLocation" "$worker" \
  '[.Statement[].Action[]] | sort == ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"]'
check "worker-ro: no Put or Delete action" "$worker" '[.Statement[].Action[] | select(test("Put|Delete"))] == []'
check "worker-ro: s3:GetObject on the bucket's objects, list and locate on the bucket, no other resource" "$worker" \
  "$by_resource == {$objects: [\"s3:GetObject\"], $bucket: [\"s3:GetBucketLocation\", \"s3:ListBucket\"]}"

# minio-init.sh against a stub mc: it logs each call's arguments, keeps the policy file each name was created from, and
# records the secret each user add reads from stdin. Fixture values only.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/mc" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG/argv"
printf '%s\n' "${MC_HOST_oj:-}" > "$STUB_LOG/mc_host"
case "$1 $2 $3" in
  "admin policy create") cp "$6" "$STUB_LOG/policy-$5.json" ;;   # admin policy create oj <name> <file>
  "admin user add") IFS= read -r secret; printf '%s %s\n' "$5" "$secret" >> "$STUB_LOG/users" ;;   # admin user add oj <key>
esac
STUB
chmod 755 "$tmp/bin/mc"
init() { # <log dir> [VAR=value...]: runs minio-init.sh with the fixture env (overridden by the arguments)
  local log=$1; shift; mkdir -p "$log"
  env -i PATH="$tmp/bin:/usr/bin:/bin" STUB_LOG="$log" MINIO_ROOT_USER=root-fixture MINIO_ROOT_PASSWORD=rootpw-fixture \
    MINIO_BUCKET=test-cases MINIO_PROBLEM_ACCESS_KEY=oj-problem MINIO_PROBLEM_SECRET_KEY=problem-secret-fixture \
    MINIO_WORKER_ACCESS_KEY=oj-worker MINIO_WORKER_SECRET_KEY=worker-secret-fixture "$@" \
    timeout 30 bash minio/minio-init.sh < /dev/null > "$log/out" 2>&1
}
rendered() { jq -S --arg b "$2" 'walk(if type == "string" then gsub("\\$\\{BUCKET\\}"; $b) else . end)' "$1"; }

if init "$tmp/ok"; then ok "minio-init.sh runs to the end with a valid env"; else bad "minio-init.sh runs to the end with a valid env: $(head -c 300 "$tmp/ok/out")"; fi
# Each policy is created from its own file: swapped files would hand the worker write access.
if [[ $(jq -S . "$tmp/ok/policy-oj-problem-rw.json" 2>/dev/null) == "$(rendered "$problem" test-cases)" \
  && $(jq -S . "$tmp/ok/policy-oj-worker-ro.json" 2>/dev/null) == "$(rendered "$worker" test-cases)" ]]; then
  ok "oj-problem-rw is created from problem-rw.json and oj-worker-ro from worker-ro.json, \${BUCKET} replaced"
else bad "oj-problem-rw is created from problem-rw.json and oj-worker-ro from worker-ro.json, \${BUCKET} replaced"; fi
# Each policy goes to its own user: a swapped attach would hand the worker write access.
if grep -qxF 'admin policy attach oj oj-problem-rw --user oj-problem' "$tmp/ok/argv" 2>/dev/null \
  && grep -qxF 'admin policy attach oj oj-worker-ro --user oj-worker' "$tmp/ok/argv" \
  && [[ $(grep -c 'admin policy attach' "$tmp/ok/argv") == 2 ]]; then
  ok "oj-problem-rw is attached to the problem key and oj-worker-ro to the worker key, nothing else"
else bad "oj-problem-rw is attached to the problem key and oj-worker-ro to the worker key, nothing else"; fi
if [[ $(cat "$tmp/ok/users" 2>/dev/null) == $'oj-problem problem-secret-fixture\noj-worker worker-secret-fixture' ]]; then
  ok "each user's secret reaches mc admin user add on stdin"
else bad "each user's secret reaches mc admin user add on stdin"; fi
if [[ -s $tmp/ok/argv ]] && ! grep -qE 'rootpw-fixture|problem-secret-fixture|worker-secret-fixture' "$tmp/ok/argv" "$tmp/ok/out" \
  && [[ $(cat "$tmp/ok/mc_host") == 'https://root-fixture:rootpw-fixture@minio:9000' ]]; then
  ok "no secret is an mc argument or printed; the root account reaches mc as MC_HOST_oj=https://…@minio:9000"
else bad "no secret is an mc argument or printed; the root account reaches mc as MC_HOST_oj=https://…@minio:9000"; fi
if grep -qx 'mb --ignore-existing oj/test-cases' "$tmp/ok/argv" 2>/dev/null; then ok "the bucket is made with --ignore-existing (kept if it exists)"
else bad "the bucket is made with --ignore-existing (kept if it exists)"; fi

refused() { # <description> <expected text in the error> <VAR=value...>: minio-init.sh exits 1 before any mc call
  local log; log=$tmp/refused-$RANDOM
  if init "$log" "${@:3}"; then bad "$1: it ran"
  elif [[ -e $log/argv ]]; then bad "$1: mc was called"
  elif ! grep -qF -- "$2" "$log/out"; then bad "$1: wanted '$2', got: $(head -c 200 "$log/out")"
  else ok "$1"; fi
}
refused "refused: the same key for problem-service and the worker" "MINIO_PROBLEM_ACCESS_KEY and MINIO_WORKER_ACCESS_KEY must differ" \
  MINIO_WORKER_ACCESS_KEY=oj-problem
refused "refused: the problem key is the root user" "MINIO_PROBLEM_ACCESS_KEY must not equal MINIO_ROOT_USER" MINIO_PROBLEM_ACCESS_KEY=root-fixture
refused "refused: the worker key is the root user" "MINIO_WORKER_ACCESS_KEY must not equal MINIO_ROOT_USER" MINIO_WORKER_ACCESS_KEY=root-fixture
refused "refused: an empty worker secret" "MINIO_WORKER_SECRET_KEY" MINIO_WORKER_SECRET_KEY=
for b in ab Test-Cases -cases cases- 'a&b' 'a/b' "$(printf 'b%.0s' {1..64})"; do
  refused "refused: bucket name '${b:0:20}'" "MINIO_BUCKET is not a valid bucket name" MINIO_BUCKET="$b"
done
if init "$tmp/dots" MINIO_BUCKET=oj.test-cases1 && grep -qx 'mb --ignore-existing oj/oj.test-cases1' "$tmp/dots/argv"; then
  ok "a bucket name with dots and digits is accepted"
else bad "a bucket name with dots and digits is accepted"; fi

exit $fail
