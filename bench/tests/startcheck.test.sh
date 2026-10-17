#!/usr/bin/env bash
# startcheck.sh lists the alerts that fired in Prometheus's first 180 s, in seconds after its start, or "none"; and it
# refuses to run without an oj-bench stack (sub-project 7 §3.4).
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
answer='{"data":{"result":[{"metric":{"alertname":"ProblemServiceDown"},"values":[[1025,"1"],[1030,"1"]]},
  {"metric":{"alertname":"ApiGatewayDown"},"values":[[1040,"1"]]}]}}'
got=$(bash startcheck.sh --format 1000 <<< "$answer" | tr '\n' ';')
if [ "$got" = "ProblemServiceDown 25 s;ApiGatewayDown 40 s;" ]; then echo "ok   each alert with its first firing, s after the start"
else echo "FAIL each alert with its first firing: $got"; fail=1; fi
got=$(bash startcheck.sh --format 1000 <<< '{"data":{"result":[]}}')
if [ "$got" = none ]; then echo "ok   nothing fired prints none"; else echo "FAIL nothing fired prints none: $got"; fail=1; fi
if [ -n "$(docker ps -q --filter label=com.docker.compose.project=oj-bench)" ]; then
  echo "skip the no-stack case: oj-bench is running"
else
  out=$(bash startcheck.sh 2>&1); code=$?
  if [ $code -ne 0 ] && grep -q 'oj-bench is not running' <<< "$out"; then echo "ok   without an oj-bench stack nothing is checked"
  else echo "FAIL without an oj-bench stack nothing is checked"; fail=1; fi
fi
exit $fail
