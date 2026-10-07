#!/usr/bin/env bash
# probe.sh dns|redis — sub-project 6 §3.2: what a stopped dependency costs, request by request, on a running oj-bench
# stack. Run before the fixes and after them; the outputs are kept in bench/results/sessions/.
#   dns    stops problem-service for 25 s: every second a read through the gateway (HTTP status, seconds) beside
#          what Docker's DNS answers for the name; then one submit (its gRPC call to problem-service); then the
#          problem-service addresses the gateway and submission-service dialled, as their logs name them.
#   redis  stops Redis for 60 s, then starts it: every 6 s a read and a submit, during the outage and for 60 s after
#          it; then the reconnect lines of the gateway and submission-service.
# Uses seeded bench users. Never prints a token: the cookie jars live in a private temporary directory.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
what=${1:-}
case "$what" in dns|redis) ;; *) die "usage: probe.sh dns|redis" ;; esac
[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$BENCH_PROJECT" --filter label=com.docker.compose.service=api-gateway)" ] \
  || die "oj-bench is not running (bench/env.sh up first)"

API=http://127.0.0.1:8000/api/v1
PASSWORD=BenchPass2026   # = USER_PASSWORD in k6/lib/config.js, bench users only
jars=$(mktemp -d); chmod 700 "$jars"; trap 'rm -rf "$jars"' EXIT

timed() { curl -s -o /dev/null -w '%{http_code} %{time_total}s' --max-time 10 "$@" || true; }
login() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -c "$jars/$1" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$PASSWORD\"}" "$API/auth/login")
  [ "$code" = 200 ] || die "login $1: HTTP $code"
}
submit() {
  timed -b "$jars/$1" -H 'Content-Type: application/json' \
    -d '{"sourceCode":"a, b = map(int, input().split())\nprint(a + b)","languageIdentifier":"python3","problemSlug":"bench-ab"}' \
    "$API/submissions"
}
since() { echo "t+$(( $(date +%s) - $1 ))s"; }
dns_answer() { docker exec oj-api-gateway nslookup "$1" 127.0.0.11 >/dev/null 2>&1 && echo resolves || echo "does not resolve"; }
dialled() { # dialled <container> <since, epoch s>: the problem-service addresses its log names
  docker logs --since "$2" "$1" 2>&1 | grep -oE 'problem-service/[0-9.]+:[0-9]+' | sort | uniq -c || true
}

probe_dns() {
  local t0
  login bench_u001
  log "read before the stop: $(timed "$API/problems")"
  t0=$(date +%s)
  "$BENCH_DIR/chaos/fault.sh" c1 inject >/dev/null
  log "problem-service stopped"
  for _ in $(seq 25); do
    log "$(since "$t0") read $(timed "$API/problems") — problem-service $(dns_answer problem-service)"
    sleep 1
  done
  log "$(since "$t0") submit $(submit bench_u001)"
  log "problem-service addresses the gateway dialled:"; dialled oj-api-gateway "$t0" >&2
  log "problem-service addresses submission-service dialled:"; dialled oj-submission-service "$t0" >&2
  "$BENCH_DIR/chaos/fault.sh" c1 remove >/dev/null
  log "problem-service started again"
}

probe_redis() {
  local users=(bench_u010 bench_u011) n=0 t0 t1
  login bench_u010; login bench_u011
  log "before the stop: read $(timed "$API/problems") submit $(submit bench_u010)"
  sleep 11   # bench_u010's submit cooldown
  t0=$(date +%s)
  "$BENCH_DIR/chaos/fault.sh" c6 inject >/dev/null
  log "redis stopped"
  while [ $(( $(date +%s) - t0 )) -lt 60 ]; do
    log "$(since "$t0") read $(timed "$API/problems") submit $(submit "${users[n++ % 2]}")"
    sleep 6
  done
  t1=$(date +%s)
  "$BENCH_DIR/chaos/fault.sh" c6 remove >/dev/null
  log "redis started again"
  while [ $(( $(date +%s) - t1 )) -lt 60 ]; do
    log "$(since "$t1") after the start: read $(timed "$API/problems") submit $(submit "${users[n++ % 2]}")"
    sleep 6
  done
  for c in oj-api-gateway oj-submission-service; do
    log "$c, reconnect lines since the stop:"
    docker logs --since "$t0" "$c" 2>&1 | grep -iE 'reconnect' | cut -c1-200 >&2 || true
  done
}

"probe_$what"
