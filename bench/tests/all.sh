#!/usr/bin/env bash
# Every bench test (spec §6): the shell checks, node tests of the k6 helpers, pytest of the data and the analysis.
set -uo pipefail
cd "$(dirname "$0")"
fail=0
for t in ./*.test.sh; do echo "== $t"; bash "$t" || fail=1; done
if compgen -G "../k6/lib/*.test.js" >/dev/null; then echo "== node --test"; node --test ../k6/lib/*.test.js || fail=1; fi
if [ -x ../analyze/pytest.sh ]; then echo "== pytest"; ../analyze/pytest.sh || fail=1; fi
if [ $fail -eq 0 ]; then echo "ALL BENCH TESTS PASS"; else echo "SOME BENCH TESTS FAILED"; fi
exit $fail
