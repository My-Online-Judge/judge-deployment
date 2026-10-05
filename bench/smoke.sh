#!/usr/bin/env bash
# A short version of every experiment on a running, seeded oj-bench stack, each with its invariant check (spec §6).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
fail=0
one() {
  local dir
  dir=$("$BENCH_DIR/run.sh" "$@" --smoke | tail -1 | sed 's/^RUN_DIR=//')
  if jq -e .ok "$dir/invariant.json" >/dev/null && [ -s "$dir/results.json" ] && [ -s "$dir/queue_depth.png" ]; then
    echo "ok   $*  ($dir)"
  else
    echo "FAIL $*  ($dir)"; fail=1
  fi
}
one e1 --rate 5
one e2 --workers 1 --steps 0.5,1
one e3 --submit-rate 0.5
one e4 --fault c3 --submit-rate 0.5
exit $fail
