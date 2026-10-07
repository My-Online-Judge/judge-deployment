#!/usr/bin/env bash
# The report's sources are in git: nothing under bench/results is left out by an ignore rule (the root *.log rule
# once kept k6.log and the session logs out), and every results/ path REPORT.md cites is tracked.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
ignored=$(git status --ignored --porcelain -- results | sed -n 's/^!! //p')
if [ -n "$ignored" ]; then echo "FAIL: ignored under results/:"; echo "$ignored"; fail=1; fi
cited=$( { grep -oE '\]\(results/[^)]+\)' REPORT.md | sed -E 's/^\]\(//; s/\)$//'
           grep -oE '`bench/results/[^`]+`' REPORT.md | tr -d '`' | sed 's#^bench/##'; } | sort -u)
for p in $cited; do
  git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || { echo "FAIL: REPORT.md cites $p, not in git"; fail=1; }
done
[ $fail -eq 0 ] && echo "PASS: the report's sources are in git ($(wc -w <<< "$cited") cited paths)"
exit $fail
