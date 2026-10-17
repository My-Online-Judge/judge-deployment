#!/usr/bin/env bash
# startcheck.sh — sub-project 7 §3.4: which alerts fired while the oj-bench stack started. Run right after env.sh up;
# it waits until Prometheus has run 180 s, then prints every alert that was firing in that window, with when it first
# fired (s after Prometheus's start), or "none". --format <t0> only formats a query_range answer read on stdin.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
WINDOW_S=180
format() { jq -r --argjson t0 "$1" \
  '[.data.result[] | "\(.metric.alertname) \((.values[0][0] - $t0) | floor) s"] | if length == 0 then "none" else .[] end'; }
if [ "${1:-}" = --format ]; then format "$2"; exit; fi
[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$BENCH_PROJECT" --filter label=com.docker.compose.service=prometheus)" ] \
  || die "oj-bench is not running (bench/env.sh up first)"
start=$(curl -sf "$PROM_URL/api/v1/status/runtimeinfo" | jq -r '.data.startTime') || die "Prometheus does not answer"
t0=$(date -d "$start" +%s)
now=$(date +%s); [ $((t0 + WINDOW_S)) -le "$now" ] || sleep $((t0 + WINDOW_S - now))
curl -sf -G "$PROM_URL/api/v1/query_range" --data-urlencode 'query=ALERTS{alertstate="firing"}' \
  --data-urlencode "start=$t0" --data-urlencode "end=$((t0 + WINDOW_S))" --data-urlencode step=5 | format "$t0"
