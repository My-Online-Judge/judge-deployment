#!/usr/bin/env bash
# probe.sh refuses a wrong argument, and refuses to run without an oj-bench stack (sub-project 6 §3.2): it stops
# containers, and only ever those of oj-bench, through chaos/fault.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
out=$(bash probe.sh nonsense 2>&1); code=$?
if [ $code -ne 0 ] && grep -q 'usage: probe.sh dns|redis|grpc|kafka' <<< "$out"; then echo "ok   a wrong argument is refused"
else echo "FAIL a wrong argument is refused"; fail=1; fi
if [ -n "$(docker ps -q --filter label=com.docker.compose.project=oj-bench)" ]; then
  echo "skip the no-stack case: oj-bench is running"
else
  out=$(bash probe.sh dns 2>&1); code=$?
  if [ $code -ne 0 ] && grep -q 'oj-bench is not running' <<< "$out"; then echo "ok   without an oj-bench stack nothing is probed"
  else echo "FAIL without an oj-bench stack nothing is probed"; fail=1; fi
  for m in grpc kafka; do
    out=$(bash probe.sh $m 2>&1); code=$?
    if [ $code -ne 0 ] && grep -q 'oj-bench is not running' <<< "$out"; then echo "ok   probe.sh $m refuses without an oj-bench stack"
    else echo "FAIL probe.sh $m refuses without an oj-bench stack"; fail=1; fi
  done
fi
exit $fail
