#!/usr/bin/env bash
# fault.sh <c1..c6> <inject|remove> — the E4 faults (spec §3.5), only ever on a container of the oj-bench project.
# c2 is a crash (no grace period); the others are stops. remove starts the same container again.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
fault=${1:-}
action=${2:-}

case "$fault" in
  c1) name=oj-problem-service ;;
  c2) name=$(docker ps -a --filter "label=com.docker.compose.project=$BENCH_PROJECT" \
               --filter label=com.docker.compose.service=judge-worker --format '{{.Names}}' | sort | head -1) ;;
  c3) name=oj-judge-server-2 ;;
  c4) name=oj-kafka ;;
  c5) name=oj-submission-service ;;
  c6) name=oj-redis ;;
  *) die "unknown fault '$fault' (c1..c6)" ;;
esac
[ -n "$name" ] || die "no container for $fault"
case "$action" in inject|remove) ;; *) die "action must be inject or remove, not '$action'" ;; esac

project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null) \
  || die "no container named $name"
[ "$project" = "$BENCH_PROJECT" ] || die "refusing: $name belongs to project '$project', not $BENCH_PROJECT"

if [ "$action" = remove ]; then
  docker start "$name" >/dev/null
elif [ "$fault" = c2 ]; then
  docker stop --time 0 "$name" >/dev/null
else
  docker stop "$name" >/dev/null
fi
echo "$fault $action $name"
