#!/usr/bin/env bash
# One measured run (spec §5): run.json → k6 (+ the fault, E4) → drain → invariant check → export.
#   run.sh e1 --rate R
#   run.sh e2 --workers N --steps 0.5,1,2,4 [--step-s 180]   |   run.sh e2 --workers N --pilot
#   run.sh e3 --submit-rate X [--read-rate 20] [--workers 1]
#   run.sh e4 --fault c1..c6 --submit-rate X [--read-rate 10] [--workers 1]
#   any: --smoke (short durations; results under results/smoke/)
# Prints RUN_DIR=<dir> last. DRY_RUN=1 prints the commands instead of running them (tests/run.test.sh).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$BENCH_DIR/lib/drain.sh"

EXP=${1:-}
[ $# -gt 0 ] && shift
RATE=20 WORKERS=1 STEPS="" STEP_S=180 SUBMIT_RATE="" READ_RATE="" FAULT="" SMOKE="" PILOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rate) RATE=$2; shift 2 ;;
    --workers) WORKERS=$2; shift 2 ;;
    --steps) STEPS=$2; shift 2 ;;
    --step-s) STEP_S=$2; shift 2 ;;
    --pilot) PILOT=1; shift ;;
    --submit-rate) SUBMIT_RATE=$2; shift 2 ;;
    --read-rate) READ_RATE=$2; shift 2 ;;
    --fault) FAULT=$2; shift 2 ;;
    --smoke) SMOKE=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done

x() { if [ -n "${DRY_RUN:-}" ]; then echo "+ $*"; else "$@"; fi; }
pause() { [ -n "${DRY_RUN:-}" ] || sleep "$1"; }
now_ms() { date +%s%3N; }
above_max() { python3 -c "import sys; sys.exit(0 if max(float(r) for r in '$1'.split(',')) > $MAX_SUBMIT_RATE else 1)"; }
need_rate() { [ -n "$SUBMIT_RATE" ] || die "$EXP needs --submit-rate"; above_max "$SUBMIT_RATE" && die "--submit-rate above $MAX_SUBMIT_RATE/s"; return 0; }

case "$EXP" in
  e1)
    SCRIPT=e1-read.js
    if [ -n "$SMOKE" ]; then W=10 M=20; else W=60 M=180; fi
    K6_ENV=(-e "RATE=$RATE" -e "WARMUP_S=$W" -e "MEASURE_S=$M")
    ARGS=$(jq -n --argjson r "$RATE" --argjson w "$W" --argjson m "$M" '{rate:$r, warmup_s:$w, measure_s:$m}')
    LABEL="e1-r$RATE" ;;
  e2)
    if [ -n "$PILOT" ]; then STEPS=0.5,1,2,4,8 STEP_S=120; fi
    [ -n "$STEPS" ] || die "e2 needs --steps or --pilot"
    above_max "$STEPS" && die "a step above $MAX_SUBMIT_RATE/s: the bench users would hit the submission cooldown"
    if [ -n "$SMOKE" ]; then STEP_S=20 W=10; else W=60; fi
    SCRIPT=e2-capacity.js
    K6_ENV=(-e "STEPS=$STEPS" -e "STEP_S=$STEP_S" -e "WARMUP_S=$W")
    ARGS=$(jq -n --argjson s "[$STEPS]" --argjson t "$STEP_S" --argjson u "$W" --argjson w "$WORKERS" --argjson p "${PILOT:-0}" \
      '{steps:$s, step_s:$t, warmup_s:$u, workers:$w, pilot:($p == 1)}')
    LABEL="e2-w$WORKERS${PILOT:+-pilot}" ;;
  e3)
    need_rate
    READ_RATE=${READ_RATE:-20}
    if [ -n "$SMOKE" ]; then W=10 M=30; else W=60 M=900; fi
    SCRIPT=e3-mixed.js
    K6_ENV=(-e "SUBMIT_RATE=$SUBMIT_RATE" -e "READ_RATE=$READ_RATE" -e "WARMUP_S=$W" -e "MEASURE_S=$M")
    ARGS=$(jq -n --argjson s "$SUBMIT_RATE" --argjson r "$READ_RATE" --argjson w "$W" --argjson m "$M" --argjson k "$WORKERS" \
      '{submit_rate:$s, read_rate:$r, warmup_s:$w, measure_s:$m, workers:$k}')
    LABEL=e3 ;;
  e4)
    case "$FAULT" in c[1-6]) ;; *) die "e4 needs --fault c1..c6" ;; esac
    need_rate
    READ_RATE=${READ_RATE:-10}
    if [ -n "$SMOKE" ]; then ST=20 FA=10 RE=20; else ST=120 FA=60 RE=180; fi
    SCRIPT=bg-load.js
    K6_ENV=(-e "SUBMIT_RATE=$SUBMIT_RATE" -e "READ_RATE=$READ_RATE" -e "STEADY_S=$ST" -e "FAULT_S=$FA" -e "RECOVER_S=$RE")
    ARGS=$(jq -n --arg f "$FAULT" --argjson s "$SUBMIT_RATE" --argjson r "$READ_RATE" --argjson a "$ST" --argjson b "$FA" --argjson c "$RE" --argjson k "$WORKERS" \
      '{fault:$f, submit_rate:$s, read_rate:$r, steady_s:$a, fault_s:$b, recover_s:$c, workers:$k}')
    LABEL="e4-$FAULT" ;;
  *) die "usage: run.sh e1|e2|e3|e4 [options] — see the header of bench/run.sh" ;;
esac

worker_count() { docker ps -q --filter "label=com.docker.compose.project=$BENCH_PROJECT" --filter label=com.docker.compose.service=judge-worker | wc -l; }
assigned_partitions() { # partitions held across the workers, from each one's latest assignment line
  local total=0 c n
  for c in $(docker ps -q --filter "label=com.docker.compose.project=$BENCH_PROJECT" --filter label=com.docker.compose.service=judge-worker); do
    n=$(docker logs "$c" 2>&1 | grep 'Setting newly assigned partitions' | tail -1 | grep -o 'partition=[0-9]*' | sort -u | wc -l)
    total=$((total + n))
  done
  echo "$total"
}
wait_workers_ready() { # the wanted number of workers, holding all 6 partitions, twice 10 s apart
  [ -n "${DRY_RUN:-}" ] && return 0
  local want=$1 deadline=$((SECONDS + 180)) good=0
  while [ $SECONDS -lt $deadline ]; do
    if [ "$(worker_count)" -eq "$want" ] && [ "$(assigned_partitions)" -eq 6 ]; then good=$((good + 1)); else good=0; fi
    [ $good -ge 2 ] && return 0
    sleep 10
  done
  die "the $want worker(s) did not settle on all 6 partitions within 180 s"
}
preflight() { # a bench stack that is up, seeded, and entirely running/healthy
  [ -n "${DRY_RUN:-}" ] && return 0
  [ "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' oj-prometheus 2>/dev/null)" = "$BENCH_PROJECT" ] \
    || die "the oj-bench stack is not up (bench/env.sh up)"
  [ -s "$BENCH_GEN/users.json" ] || die "the stack is not seeded (.gen/users.json is missing)"
  local unhealthy
  unhealthy=$(docker ps -aq --filter "label=com.docker.compose.project=$BENCH_PROJECT" | xargs docker inspect \
    --format '{{.Name}} {{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    | awk '$2 != "true" || ($3 != "healthy" && $3 != "none") {print $1}')
  [ -z "$unhealthy" ] || die "not every oj-bench container is running and healthy:$(echo " $unhealthy" | tr '\n' ' ')"
}
repo_shas() {
  local out='{}' r dir
  for r in judge-deployment oj-common oj-api-gateway oj-identity-service oj-problem-service oj-submission-service judge-worker; do
    dir="$OJ_ROOT/$r"; [ "$r" = judge-deployment ] && dir="$BENCH_DIR/.."
    out=$(jq --arg r "$r" --arg s "$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)" '. + {($r): $s}' <<< "$out")
  done
  echo "$out"
}
image_ids() {
  [ -n "${DRY_RUN:-}" ] && { echo '{}'; return; }
  docker ps --filter "label=com.docker.compose.project=$BENCH_PROJECT" --format '{{.Names}}' | sort | while read -r n; do
    echo "$n $(docker inspect --format '{{.Image}}' "$n" | cut -c8-19)"
  done | jq -R -s 'split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[1]}) | add // {}'
}
k6_run() { # k6_run <script> [-e K=V…] — output in RUN_DIR; remote write tagged testid=RUN_ID
  local script=$1; shift
  x docker run --rm --name "oj-bench-k6-$RUN_ID" --network oj-net --cpus 1 --user "$(id -u):$(id -g)" \
    -v "$BENCH_DIR/k6:/scripts:ro" -v "$BENCH_DIR/data:/data:ro" -v "$BENCH_GEN:/gen:ro" -v "$RUN_DIR:/out" \
    -e K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write -e 'K6_PROMETHEUS_RW_TREND_STATS=p(50),p(95),p(99),count' \
    "$@" "$K6_IMAGE" run --quiet --tag "testid=$RUN_ID" --log-output=file=/out/k6.log --log-format=json \
    -o experimental-prometheus-rw "/scripts/$script"
}
wait_setup_done() {
  [ -n "${DRY_RUN:-}" ] && return 0
  local deadline=$((SECONDS + 300))
  until grep -q 'setup-done' "$RUN_DIR/k6.log" 2>/dev/null; do
    [ $SECONDS -lt $deadline ] || die "k6 setup did not finish within 300 s"
    sleep 1
  done
}

preflight
RESULTS="${BENCH_RESULTS:-$BENCH_DIR/results}${SMOKE:+/smoke}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$LABEL"
RUN_DIR="$RESULTS/$RUN_ID"
mkdir -p "$RUN_DIR"
meta_set() { local f="$RUN_DIR/run.json"; jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }

if [ "$EXP" != e1 ]; then
  x bench_compose up -d --no-build --no-deps --scale "judge-worker=$WORKERS" judge-worker
  wait_workers_ready "$WORKERS"
fi
jq -n --arg id "$RUN_ID" --arg exp "$EXP" --argjson args "$ARGS" --argjson smoke "${SMOKE:-0}" --argjson git "$(repo_shas)" \
  --argjson images "$(image_ids)" --arg load "$(cut -d' ' -f1-3 /proc/loadavg)" --argjson started "$(date +%s)" \
  '{id:$id, exp:$exp, args:$args, smoke:($smoke == 1), git:$git, images:$images, loadavg_before:$load, workers:($args.workers // null), started_at:$started}' \
  > "$RUN_DIR/run.json"
log "run $RUN_ID"

if [ "$EXP" = e4 ]; then
  if [ -n "${DRY_RUN:-}" ]; then k6_run "$SCRIPT" "${K6_ENV[@]}"; else k6_run "$SCRIPT" "${K6_ENV[@]}" >&2 & K6_PID=$!; fi
  wait_setup_done
  pause "$ST"
  t=$(now_ms); x "$BENCH_DIR/chaos/fault.sh" "$FAULT" inject; meta_set --argjson t "$t" '.fault.inject_ms = $t'
  pause "$FA"
  x "$BENCH_DIR/chaos/fault.sh" "$FAULT" remove; t=$(now_ms); meta_set --argjson t "$t" '.fault.remove_ms = $t'
  [ -n "${DRY_RUN:-}" ] || wait "$K6_PID" || die "k6 failed — see $RUN_DIR/k6.log"
else
  k6_run "$SCRIPT" "${K6_ENV[@]}" >&2 || die "k6 failed — see $RUN_DIR/k6.log"
fi
meta_set --argjson t "$(date +%s)" '.load_ended_at = $t'

if [ -n "${DRY_RUN:-}" ]; then outcome=skipped; else outcome=$(drain_queue "${DRAIN_MAX_S:-1200}"); fi
meta_set --arg d "$outcome" '.drain = $d'
[ "$outcome" = timeout ] && log "the judge queue did not empty — the invariant check will list what is stuck"
meta_set --argjson t "$(date +%s)" '.ended_at = $t'

x docker run --rm --network oj-net --user "$(id -u):$(id -g)" -v "$BENCH_DIR/k6:/scripts:ro" -v "$BENCH_GEN:/gen:ro" \
  -v "$RUN_DIR:/out" "$K6_IMAGE" run --quiet /scripts/check.js >&2
REL=${RUN_DIR#"$BENCH_DIR"/}
x analyze invariant "$REL" >&2
x analyze export "$REL" >&2
echo "RUN_DIR=$RUN_DIR"
