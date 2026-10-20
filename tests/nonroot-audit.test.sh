#!/usr/bin/env bash
# ci: skip (needs docker and the alpine image)
# scripts/nonroot-audit.sh (sp12 task 13) against two throwaway containers labelled with a scratch compose project:
# `asroot` runs as root, `asuser` as uid 10001. Never touches the live project.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
project=nonroot-$$
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
cleanup() { docker --context default rm -f "$project-asroot" "$project-asuser" >/dev/null 2>&1; }
trap cleanup EXIT
run() { # run <service> [docker run args...]
  local svc=$1; shift
  docker --context default run -d --name "$project-$svc" --label "com.docker.compose.project=$project" \
    --label "com.docker.compose.service=$svc" "$@" alpine:3.22 sleep 300 >/dev/null
}
run asroot
run asuser --user 10001
sleep 1

out=$(scripts/nonroot-audit.sh "$project" 2>&1); rc=$?
[[ $rc == 1 ]] && ok "exit 1 when a service runs as root" || bad "exit 1 when a service runs as root (rc $rc)"
grep -qx 'ROOT asroot sleep' <<< "$out" && ok "prints 'ROOT asroot sleep'" || bad "prints 'ROOT asroot sleep' (got: $out)"
grep -q 'asuser' <<< "$out" && bad "the uid 10001 service is not reported" || ok "the uid 10001 service is not reported"

out=$(NONROOT_ALLOW=asroot scripts/nonroot-audit.sh "$project" 2>&1); rc=$?
[[ $rc == 0 && $out == PASS ]] && ok "NONROOT_ALLOW=asroot -> PASS, exit 0" || bad "NONROOT_ALLOW=asroot -> PASS (rc $rc, got: $out)"

echo; [[ $fails == 0 ]] && echo "nonroot-audit.test.sh: all passed" || echo "nonroot-audit.test.sh: $fails FAILED"
exit $((fails > 0))
