#!/usr/bin/env bash
# up | down | status of the oj-bench stack (sub-project 5, spec §4.2).
#   up [--history]  refuses while any container of the live project exists (fixed names and networks would
#                   collide); starts every service but the portal from the live images on fresh oj-bench volumes;
#                   waits for health; seeds (seed.sh; --history adds E1's submission history).
#   down            removes the oj-bench containers and ONLY the oj-bench volumes.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

# The image compose gives a built service: ${OJ_REGISTRY:-docker.io/thanhtuanle}/<name>:${OJ_<X>_TAG:-${OJ_TAG:-main}}
# (docker-compose.yml). The overlay runs exactly that, never pulled.
built_image() {
  local name var
  case "$1" in
    submission-service) name=oj-submission-service var=OJ_SUBMISSION_TAG ;;
    identity-service) name=oj-identity-service var=OJ_IDENTITY_TAG ;;
    problem-service) name=oj-problem-service var=OJ_PROBLEM_TAG ;;
    api-gateway) name=oj-api-gateway var=OJ_GATEWAY_TAG ;;
    judge-worker) name=judge-worker var=OJ_WORKER_TAG ;;
    *) die "no image known for $1" ;;
  esac
  echo "${OJ_REGISTRY:-docker.io/thanhtuanle}/$name:${!var:-${OJ_TAG:-main}}"
}

live_containers() { docker ps -aq --filter "label=com.docker.compose.project=$LIVE_PROJECT"; }

case "${1:-}" in
  up)
    shift
    [ -z "$(live_containers)" ] || die "the live stack ($LIVE_PROJECT) still has containers. Stop it first, keeping its data: cd $DEPLOY_DIR && docker compose down"
    for s in "${BUILT_SERVICES[@]}"; do
      img=$(built_image "$s")
      docker image inspect "$img" >/dev/null 2>&1 || die "image $img is missing (docker compose build $s, or pull it)"
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
