#!/usr/bin/env bash
# Every experiment script parses in k6 and resolves to the scenarios the spec describes (spec §3). The env goes in as
# container env with --include-system-env-vars, the way `k6 run` (default on) reads it in run.sh; k6 prints durations
# in Go form (60s → "1m0s").
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/gen"
python3 -c "import json; print(json.dumps({f'bench_u{i:03d}': f'00000000-0000-0000-0000-{i:012d}' for i in range(1, 201)}))" > "$tmp/gen/users.json"
fail=0
inspect() { # inspect <script> [-e K=V…] → the resolved options as JSON
  local script=$1; shift
  docker run --rm --user "$(id -u):$(id -g)" -v "$BENCH_DIR/k6:/scripts:ro" -v "$BENCH_DIR/data:/data:ro" -v "$tmp/gen:/gen:ro" \
    "$@" "$K6_IMAGE" inspect --include-system-env-vars "/scripts/$script"
}
expect() { # expect <description> <jq boolean expression> <inspect args…>
  local desc=$1 expr=$2; shift 2
  if inspect "$@" 2>"$tmp/err" | jq -e "$expr" >/dev/null; then echo "ok   $desc"; else echo "FAIL $desc"; sed -n 1,5p "$tmp/err"; fail=1; fi
}
expect "E1: warm-up then measure at the given rate, sub-metrics per read route" \
  '(.scenarios.warmup.rate == 50) and (.scenarios.measure.startTime == "1m0s") and (.scenarios.measure.duration == "3m0s") and (.thresholds | has("http_req_duration{phase:measure,route:history}"))' \
  e1-read.js -e RATE=50
expect "E2: a 60 s warm-up at the first rate, then the steps per minute with 5 s ramps" \
  '.scenarios.submit.stages == [{"target":30,"duration":"5s"},{"target":30,"duration":"1m0s"},{"target":30,"duration":"5s"},{"target":30,"duration":"3m0s"},{"target":60,"duration":"5s"},{"target":60,"duration":"3m0s"}]' \
  e2-capacity.js -e STEPS=0.5,1
expect "E3: the measured submits continue the warm-up's rotation" \
  '(.scenarios.submits.env.USER_OFFSET == "40") and (.scenarios.submits.duration == "15m0s") and (.scenarios.reads.rate == 20)' \
  e3-mixed.js -e SUBMIT_RATE=0.5
expect "E4: reads and submits for steady + fault + recovery" \
  '(.scenarios.reads.duration == "6m0s") and (.scenarios.submits.rate == 30) and (.scenarios.submits.timeUnit == "1m0s")' \
  bg-load.js -e SUBMIT_RATE=0.5
expect "check: one iteration, a long setup" '(.setupTimeout == "15m0s")' check.js
if inspect e2-capacity.js -e STEPS=0.5,19 >/dev/null 2>&1; then echo "FAIL E2 refuses a step above 18/s"; fail=1; else echo "ok   E2 refuses a step above 18/s"; fi
if inspect e3-mixed.js >/dev/null 2>&1; then echo "FAIL E3 needs SUBMIT_RATE"; fail=1; else echo "ok   E3 needs SUBMIT_RATE"; fi
exit $fail
