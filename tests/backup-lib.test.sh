#!/usr/bin/env bash
# backup/lib.sh compare_counts: PASS/FAIL lines and exit status (SP9 T9).
set -uo pipefail
cd "$(dirname "$0")/.."
source backup/lib.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
tab=$'\t'
mk() { printf '%s\n' "$@" | sed "s/ /$tab/" ; }
check() { # name want_rc want_regex expected actual
  local out rc=0
  out=$(compare_counts "$4" "$5" 2>&1) || rc=$?
  if [ "$rc" = "$2" ] && grep -Eq -- "$3" <<<"$out"; then echo "ok   $1"
  else echo "FAIL $1: rc=$rc (want $2), output:"; echo "$out"; fail=1; fi
}
mk "t_users 5" "t_problems 3" > "$tmp/exp"
mk "t_users 5" "t_problems 3" > "$tmp/same"
mk "t_users 4" "t_problems 3" > "$tmp/diff"
mk "t_problems 3" > "$tmp/missing"
mk "t_users 5" "t_problems 3" "extra 1" > "$tmp/extra"

check "identical passes" 0 '^PASS t_users 5$' "$tmp/exp" "$tmp/same"
out=$(compare_counts "$tmp/exp" "$tmp/same"); grep -q FAIL <<<"$out" && { echo "FAIL identical has FAIL line"; fail=1; }
check "differing count fails" 1 '^FAIL t_users expected=5 actual=4$' "$tmp/exp" "$tmp/diff"
check "missing in actual fails" 1 '^FAIL t_users expected=5 actual=' "$tmp/exp" "$tmp/missing"
check "extra in actual fails" 1 '^FAIL extra expected= actual=1$' "$tmp/exp" "$tmp/extra"
exit $fail
