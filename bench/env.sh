#!/usr/bin/env bash
# up | down | status of the oj-bench stack (sub-project 5, spec §4.2).
#   up [--history]  refuses while any container of the live project exists (fixed names and networks would
#                   collide); starts every service but the portal from the live images on fresh oj-bench volumes;
#                   waits for health; seeds (seed.sh; --history adds E1's submission history).
#   down            removes the oj-bench containers and ONLY the oj-bench volumes.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

live_containers() { docker ps -aq --filter "label=com.docker.compose.project=$LIVE_PROJECT"; }

case "${1:-}" in
  up)
    shift
    [ -z "$(live_containers)" ] || die "the live stack ($LIVE_PROJECT) still has containers. Stop it first, keeping its data: cd $DEPLOY_DIR && docker compose down"
    for s in "${BUILT_SERVICES[@]}"; do
      docker image inspect "judge-deployment-$s:latest" >/dev/null 2>&1 || die "image judge-deployment-$s:latest is missing"
    done
    "$BENCH_DIR/gen-prometheus.sh"
    log "starting $BENCH_PROJECT on fresh volumes"
    bench_compose up -d --no-build --wait --wait-timeout 600
    if [ -z "${BENCH_SKIP_SEED:-}" ]; then "$BENCH_DIR/seed.sh" "$@"; fi
    ;;
  down)
    bench_compose down -v --remove-orphans
    ;;
  status)
    bench_compose ps
    ;;
  *)
    die "usage: env.sh up [--history] | down | status"
    ;;
esac
