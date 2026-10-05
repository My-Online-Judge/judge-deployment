#!/usr/bin/env bash
# run.sh builds the right commands in the right order (DRY_RUN prints them), and refuses what would mismeasure.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
res=$(mktemp -d); trap 'rm -rf "$res"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
run() { DRY_RUN=1 BENCH_RESULTS="$res" "$here/../run.sh" "$@" 2>&1; }
line_of() { grep -n -- "$1" <<< "$2" | head -1 | cut -d: -f1; }

out=$(run e1 --rate 50)
for want in '--cpus 1' '--network oj-net' '-o experimental-prometheus-rw' '--tag testid=' '/scripts/e1-read.js' '-e RATE=50' '--log-output=file=/out/k6.log'; do
  if grep -q -- "$want" <<< "$out"; then ok "e1 k6 command has $want"; else bad "e1 k6 command has $want"; fi
done
dir=$(tail -1 <<< "$out" | sed 's/^RUN_DIR=//')
if jq -e '.exp == "e1" and .args.rate == 50 and .args.measure_s == 180' "$dir/run.json" >/dev/null; then ok "run.json records the experiment and its arguments"; else bad "run.json records the experiment and its arguments"; fi

out=$(run e2 --workers 4 --steps 0.5,1,2,4)
if [ "$(line_of 'scale judge-worker=4' "$out")" -lt "$(line_of '/scripts/e2-capacity.js' "$out")" ]; then ok "e2 scales to 4 workers before the load"; else bad "e2 scales to 4 workers before the load"; fi
if grep -q -- '-e STEPS=0.5,1,2,4' <<< "$out"; then ok "e2 passes its steps"; else bad "e2 passes its steps"; fi
if run e2 --workers 1 --steps 0.5,18.5 >/dev/null; then bad "a step above 18/s is refused"; else ok "a step above 18/s is refused"; fi
if run e2 --workers 1 --steps 0.5,18 >/dev/null; then ok "18/s is allowed"; else bad "18/s is allowed"; fi
out=$(run e2 --workers 2 --pilot)
if grep -q -- '-e STEPS=0.5,1,2,4,8' <<< "$out" && grep -q -- '-e STEP_S=120' <<< "$out"; then ok "a pilot runs 0.5..8/s at 120 s"; else bad "a pilot runs 0.5..8/s at 120 s"; fi

out=$(run e4 --fault c1 --submit-rate 1)
a=$(line_of '/scripts/bg-load.js' "$out"); b=$(line_of 'fault.sh c1 inject' "$out"); c=$(line_of 'fault.sh c1 remove' "$out")
d=$(line_of '/scripts/check.js' "$out"); e=$(line_of 'analyze invariant' "$out"); f=$(line_of 'analyze export' "$out")
if [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] && [ "$e" -lt "$f" ]; then
  ok "e4: load, inject, remove, check, invariant, export — in that order"; else bad "e4: load, inject, remove, check, invariant, export — in that order"; fi
if run e4 --fault c9 --submit-rate 1 >/dev/null; then bad "an unknown fault is refused"; else ok "an unknown fault is refused"; fi
if run e3 >/dev/null; then bad "e3 needs a submit rate"; else ok "e3 needs a submit rate"; fi

out=$(run e4 --smoke --fault c3 --submit-rate 0.5)
if grep -q -- '-e STEADY_S=20' <<< "$out" && grep -q "RUN_DIR=$res/smoke/" <<< "$out"; then ok "--smoke shortens the run and files it under smoke/"; else bad "--smoke shortens the run and files it under smoke/"; fi
exit $fail
