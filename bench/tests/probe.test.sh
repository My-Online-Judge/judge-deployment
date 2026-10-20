#!/usr/bin/env bash
# probe.sh refuses a wrong argument, and refuses to run without an oj-bench stack (sub-project 6 §3.2): it stops
# containers, and only ever those of oj-bench, through chaos/fault.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
out=$(bash probe.sh nonsense 2>&1); code=$?
if [ $code -ne 0 ] && grep -q 'usage: probe.sh dns|redis|grpc|kafka|worker|minio' <<< "$out"; then echo "ok   a wrong argument is refused"
else echo "FAIL a wrong argument is refused"; fail=1; fi
if [ -n "$(docker ps -q --filter label=com.docker.compose.project=oj-bench)" ]; then
  echo "skip the no-stack case: oj-bench is running"
else
  out=$(bash probe.sh dns 2>&1); code=$?
  if [ $code -ne 0 ] && grep -q 'oj-bench is not running' <<< "$out"; then echo "ok   without an oj-bench stack nothing is probed"
  else echo "FAIL without an oj-bench stack nothing is probed"; fail=1; fi
  for m in grpc kafka worker minio; do
    out=$(bash probe.sh $m 2>&1); code=$?
    if [ $code -ne 0 ] && grep -q 'oj-bench is not running' <<< "$out"; then echo "ok   probe.sh $m refuses without an oj-bench stack"
    else echo "FAIL probe.sh $m refuses without an oj-bench stack"; fail=1; fi
  done
fi

# probe_minio clears the bundle cache of EVERY bench worker (one worker would leave the others' cached bundles and the
# "retries grew" expectation to chance). The function is cut out of probe.sh and run against stubs.
stub=$(mktemp -d); trap 'rm -rf "$stub"' EXIT
sed -n '/^probe_minio() {/,/^}/p' probe.sh > "$stub/fn.sh"
cat > "$stub/run.sh" <<'HARNESS'
log() { :; }; die() { echo "die: $*" >&2; exit 1; }; since() { echo t+0s; }; sleep() { :; }
bench_workers() { printf '%s\n' w1 w2 w3; }
in_bench() { echo "in_bench $1" >> "$STUB_LOG"; }
login() { :; }; prom_sum() { echo 0; }; submit_id() { echo 1; }; wait_terminal() { echo 5; }
curl() { echo '{}'; }; jq() { echo none; }; date() { echo $(( $(cat "$STUB_LOG.t" 2>/dev/null || echo 0) + 100 )) | tee "$STUB_LOG.t"; }
docker() { echo "docker $*" >> "$STUB_LOG"; }
jars=/nonexistent; API=x
source "$STUB_FN"
probe_minio
HARNESS
STUB_LOG=$stub/log STUB_FN=$stub/fn.sh bash "$stub/run.sh" >/dev/null 2>&1 || true
touch "$stub/log"
for w in w1 w2 w3; do
  if grep -q "^docker exec $w sh -c rm -rf /test_case/\*__\*" "$stub/log" && grep -q "^in_bench $w$" "$stub/log"; then
    echo "ok   probe minio: $w is guarded by in_bench and its bundle cache cleared"
  else echo "FAIL probe minio: $w is guarded by in_bench and its bundle cache cleared"; fail=1; fi
done
exit $fail
