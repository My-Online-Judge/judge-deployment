#!/usr/bin/env bash
# scripts/preflight.sh refuses to build from a sibling repo that is off main, dirty, missing or not a git repo (SP9 T7).
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/scripts/preflight.sh"
repos="judge-portal judge-worker oj-common oj-api-gateway oj-identity-service oj-problem-service oj-submission-service"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail=0

# A fresh OJ_ROOT in $root: every repo clean on main, tracking a bare origin.
fresh() {
  root="$tmp/$1"; mkdir -p "$root"
  for r in $repos; do
    git init -q -b main --bare "$root/$r.origin.git"
    git init -q -b main "$root/$r"
    git -C "$root/$r" remote add origin "$root/$r.origin.git"
    echo x > "$root/$r/f"; git -C "$root/$r" add f; git -C "$root/$r" commit -q -m init
    git -C "$root/$r" push -q origin main
  done
}
# check <name> <want exit> <want output regex>: runs the script against $root.
check() {
  local out rc=0
  out=$(OJ_ROOT="$root" bash "$script" 2>&1) || rc=$?
  if [ "$rc" = "$2" ] && grep -Eq -- "$3" <<<"$out"; then echo "ok   $1"
  else echo "FAIL $1: exit $rc (want $2), output:"; echo "$out"; fail=1; fi
}

fresh clean;   check "all clean on main passes" 0 '^OK oj-common$'
fresh branch;  git -C "$root/oj-common" checkout -q -b feature/x
check "repo on a feature branch fails" 1 '^FAIL oj-common: on branch feature/x, not main$'
fresh dirty;   echo y > "$root/judge-worker/f"
check "modified tracked file fails" 1 '^FAIL judge-worker: uncommitted changes$'
fresh untracked; echo y > "$root/judge-worker/new"
check "untracked file does not fail" 0 '^OK judge-worker$'
fresh missing; rm -rf "$root/judge-portal"
check "missing repo fails" 1 '^FAIL judge-portal: missing$'
fresh nogit;   rm -rf "$root/oj-problem-service/.git"
check "directory without .git fails" 1 '^FAIL oj-problem-service: not a git repo$'
fresh enclosed; git init -q -b main "$root"; rm -rf "$root/oj-problem-service/.git"
check "sibling without .git inside an enclosing repo fails" 1 '^FAIL oj-problem-service: not a git repo$'
fresh behind
git clone -q "$root/oj-identity-service.origin.git" "$tmp/other"
echo z >> "$tmp/other/f"; git -C "$tmp/other" commit -q -am more; git -C "$tmp/other" push -q origin main
git -C "$root/oj-identity-service" fetch -q
check "repo behind origin warns but passes" 0 '^WARN oj-identity-service: behind origin/main by 1$'
exit $fail
