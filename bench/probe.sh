#!/usr/bin/env bash
# probe.sh dns|redis — sub-project 6 §3.2: what a stopped dependency costs, request by request, on a running oj-bench
# stack. Run before the fixes and after them; the outputs are kept in bench/results/sessions/.
#   dns    stops problem-service for 25 s: every second a read through the gateway (HTTP status, seconds) beside
#          what Docker's DNS answers for the name; then one submit (its gRPC call to problem-service); then the
#          problem-service addresses the gateway and submission-service dialled, as their logs name them.
#   redis  stops Redis for 60 s, then starts it: every 6 s a read and a submit, during the outage and for 60 s after
#          it; then the reconnect lines of the gateway and submission-service.
#   grpc   stops problem-service for 60 s: every 3 s a submit (four users in turn, past the 10 s cooldown) and a read,
#          each with its HTTP status and time; then submission-service's failed GetJudgeSpec calls by gRPC status
#          (DEADLINE_EXCEEDED: the call waited on a connect; UNAVAILABLE: the channel failed fast); then a submit every
#          15 s for a minute after the restart (sub-project 7 §3.1); then submission-service's channel trace lines
#          (ChannelLogger, with BENCH_EXTRA_COMPOSE=bench/compose.grpc-trace.yml; ChannelRecovery) since the stop (sub-project 8).
#   kafka  submits a solution that sleeps 2.5 s per test, kills Kafka the moment the worker logs that it is judging
#          it, holds Kafka down 60 s and starts it: the worker's restart count before and after, whether Prometheus
#          scraped a worker meanwhile, how long after Kafka's start the submission was terminal (sub-project 7 §3.2),
#          and how many seconds the worker spent waiting to resend (oj_verdict_publish_wait_seconds_total, sub-project 8).
# Uses seeded bench users. Never prints a token: the cookie jars live in a private temporary directory.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
what=${1:-}
case "$what" in dns|redis|grpc|kafka) ;; *) die "usage: probe.sh dns|redis|grpc|kafka" ;; esac
[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$BENCH_PROJECT" --filter label=com.docker.compose.service=api-gateway)" ] \
  || die "oj-bench is not running (bench/env.sh up first)"

API=https://localhost/api/v1   # the edge (sub-project 10); the gateway has no host port
[ -f "$OJ_CA" ] || die "the CA certificate is missing: $OJ_CA (pki/pki.sh init-ca, or set OJ_CA)"
curl() { command curl --cacert "$OJ_CA" "$@"; }
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
submit_id() { # submit_id <user> <slug> <python source> — prints the new submission's id (empty if refused)
  curl -s -b "$jars/$1" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg slug "$2" --arg s "$3" '{sourceCode:$s, languageIdentifier:"python3", problemSlug:$slug}')" \
    "$API/submissions" | jq -r '.data.id // empty'
}
status_of() { curl -s -b "$jars/$1" "$API/submissions/$2" | jq -r '.data.status // empty'; }  # 6 PENDING, 7 JUDGING
publish_wait() { curl -s -G "$PROM_URL/api/v1/query" --data-urlencode 'query=sum(oj_verdict_publish_wait_seconds_total) or vector(0)' \
  | jq -r '.data.result[0].value[1] // "0"'; }
worker_up() { curl -s -G "$PROM_URL/api/v1/query" --data-urlencode 'query=max(up{job="judge-worker"})' \
  | jq -r '.data.result[0].value[1] // "absent"'; }

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

probe_grpc() {
  local users=(bench_u030 bench_u031 bench_u032 bench_u033) n=0 t0 t1 u
  for u in "${users[@]}"; do login "$u"; done
  log "before the stop: submit $(submit bench_u030)"
  sleep 11   # bench_u030's submit cooldown
  n=1
  t0=$(date +%s)
  "$BENCH_DIR/chaos/fault.sh" c1 inject >/dev/null
  log "problem-service stopped"
  while [ $(( $(date +%s) - t0 )) -lt 60 ]; do
    log "$(since "$t0") submit $(submit "${users[n++ % 4]}") read $(timed "$API/problems")"
    sleep 3
  done
  log "submission-service's failed GetJudgeSpec calls since the stop, by gRPC status:"
  docker logs --since "$t0" oj-submission-service 2>&1 | grep 'could not give the judge spec' \
    | grep -oE 'code=[A-Z_]+' | sort | uniq -c >&2 || true
  log "channel trace since the stop:"
  docker logs --since "$t0" oj-submission-service 2>&1 | grep -E 'ChannelLogger|ChannelRecovery' | cut -c1-220 >&2 || true
  "$BENCH_DIR/chaos/fault.sh" c1 remove >/dev/null
  t1=$(date +%s)
  log "problem-service started again"
  for _ in 1 2 3 4; do sleep 15; log "$(since "$t1") after the start: submit $(submit "${users[n++ % 4]}")"; done
}

probe_kafka() {
  local worker id t0 t1 st before after w0 seen=
  worker=$(docker ps --filter "label=com.docker.compose.project=$BENCH_PROJECT" \
    --filter label=com.docker.compose.service=judge-worker --format '{{.Names}}' | sort | head -1)
  [ -n "$worker" ] || die "no judge-worker is running in $BENCH_PROJECT"
  [ "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' oj-kafka)" = "$BENCH_PROJECT" ] \
    || die "oj-kafka does not belong to $BENCH_PROJECT"
  login bench_u020
  before=$(docker inspect --format '{{.RestartCount}}' "$worker")
  t0=$(date +%s)
  id=$(submit_id bench_u020 bench-sum $'import time\ntime.sleep(2.5)\n')
  [ -n "$id" ] || die "the submit was refused"
  for _ in $(seq 100); do
    docker logs --since "$t0" "$worker" 2>&1 | grep -q "Judging submission $id" && { seen=1; break; }
    sleep 0.1
  done
  [ -n "$seen" ] || die "the worker did not start judging $id within 10 s"
  w0=$(publish_wait)
  docker kill oj-kafka >/dev/null
  t1=$(date +%s)
  log "$(since "$t0") Kafka killed while the worker judges $id"
  for _ in $(seq 12); do
    sleep 5
    log "$(since "$t1") worker restarts $(docker inspect --format '{{.RestartCount}}' "$worker"), state" \
      "$(docker inspect --format '{{.State.Status}}' "$worker"), scraped up: $(worker_up)"
  done
  "$BENCH_DIR/chaos/fault.sh" c4 remove >/dev/null
  t1=$(date +%s)
  log "Kafka started again"
  for _ in $(seq 120); do
    st=$(status_of bench_u020 "$id"); case "$st" in 6|7|'') sleep 1 ;; *) break ;; esac
  done
  log "$(since "$t1") after Kafka's start: submission $id status $st (6 PENDING and 7 JUDGING are not terminal)"
  sleep 6   # one bench scrape (5 s) after the verdict
  log "publish wait: $(awk -v a="$w0" -v b="$(publish_wait)" 'BEGIN { printf "%.1f", b - a }') s over the outage"
  after=$(docker inspect --format '{{.RestartCount}}' "$worker")
  log "worker restarts: $before before, $after after"
  log "the worker's log about Kafka since the submit:"
  docker logs --since "$t0" "$worker" 2>&1 \
    | grep -E 'not published|Offset commit failed|No Kafka broker|Traceback|KafkaTimeoutError|NoBrokersAvailable' \
    | cut -c1-200 >&2 || true
}

"probe_$what"
