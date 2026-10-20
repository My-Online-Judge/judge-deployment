#!/usr/bin/env bash
# backup/lib.sh compare_counts: PASS/FAIL lines and exit status (SP9 T9).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source backup/lib.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
tab=$'\t'
mk() { printf '%s\n' "$@" | sed "s/ /$tab/g" ; }
check() { # name want_rc want_regex expected actual
  local out rc=0
  out=$(compare_counts "$4" "$5" 2>&1) || rc=$?
  if [ "$rc" = "$2" ] && grep -Eq -- "$3" <<<"$out"; then echo "ok   $1"
  else echo "FAIL $1: rc=$rc (want $2), output:"; echo "$out"; fail=1; fi
}
mk "t_users 5 5" "t_submissions 10 14" "t_outbox 0 3" > "$tmp/exp"
mk "t_users 5" "t_submissions 12" "t_outbox 99" > "$tmp/same"
mk "t_users 4" "t_submissions 12" "t_outbox 0" > "$tmp/diff"
mk "t_users 5" "t_submissions 9" "t_outbox 0" > "$tmp/below"
mk "t_users 5" "t_submissions 15" "t_outbox 0" > "$tmp/above"
mk "t_submissions 12" "t_outbox 0" > "$tmp/missing"
mk "t_users 5" "t_submissions 14" "t_outbox 0" "extra 1" > "$tmp/extra"
mk "t_users 5" "t_submissions 10" > "$tmp/noinfo"

check "in-range passes (bounds inclusive)" 0 '^PASS t_submissions 12$' "$tmp/exp" "$tmp/same"
check "informational row never fails" 0 '^INFO t_outbox expected=0..3 actual=99$' "$tmp/exp" "$tmp/same"
check "lower bound passes" 0 '^PASS t_submissions 10$' "$tmp/exp" "$tmp/noinfo"
check "exact row differing fails" 1 '^FAIL t_users expected=5..5 actual=4$' "$tmp/exp" "$tmp/diff"
check "below range fails" 1 '^FAIL t_submissions expected=10..14 actual=9$' "$tmp/exp" "$tmp/below"
check "above range fails" 1 '^FAIL t_submissions expected=10..14 actual=15$' "$tmp/exp" "$tmp/above"
check "missing in actual fails" 1 '^FAIL t_users expected=5..5 actual=$' "$tmp/exp" "$tmp/missing"
check "extra in actual fails" 1 '^FAIL extra expected= actual=1$' "$tmp/exp" "$tmp/extra"
exit $fail
