#!/usr/bin/env bash
# Deploy preflight: the stack builds from sibling checkouts, so refuse to build when one is missing, not a git repo,
# off main, or has uncommitted changes to tracked files. Behind origin/main only warns (uses the last fetch).
# OJ_ROOT defaults to the parent of judge-deployment.
set -uo pipefail
root=${OJ_ROOT:-$(dirname "$(cd "$(dirname "$0")/.." && pwd)")}
fail=0
for r in judge-portal judge-worker oj-common oj-api-gateway oj-identity-service oj-problem-service oj-submission-service; do
  d="$root/$r"
  if [ ! -d "$d" ]; then echo "FAIL $r: missing"; fail=1; continue; fi
  if ! git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then echo "FAIL $r: not a git repo"; fail=1; continue; fi
  branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$branch" != main ]; then echo "FAIL $r: on branch $branch, not main"; fail=1; continue; fi
  if [ -n "$(git -C "$d" status --porcelain --untracked-files=no)" ]; then echo "FAIL $r: uncommitted changes"; fail=1; continue; fi
  behind=$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ]; then echo "WARN $r: behind origin/main by $behind"; else echo "OK $r"; fi
done
exit $fail
