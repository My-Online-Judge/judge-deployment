#!/usr/bin/env bash
# The measured campaign (spec §7 phase B), one experiment family per call, on a running oj-bench stack:
#   campaign.sh e2-pilots              one pilot per worker count (1 2 4 6), then the measured step list of each
#   campaign.sh e2 <workers> <steps>   3 runs
#   campaign.sh e1                     3 rounds of 20, 50, 100 req/s (the stack seeded with env.sh up --history)
#   campaign.sh e3 <submit-rate>       3 runs
#   campaign.sh e4 <submit-rate>       3 rounds of c1..c6; a failed run re-creates the stack and runs again
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
RUN=${RUN_SH:-$BENCH_DIR/run.sh}
ENV=${ENV_SH:-$BENCH_DIR/env.sh}
REPEATS=${REPEATS:-3}
run() { "$RUN" "$@" | tail -1; }

case "${1:-}" in
  e2-pilots)
    for w in 1 2 4 6; do
      dir=$(run e2 --pilot --workers "$w" | sed 's/^RUN_DIR=//')
      echo "workers=$w steps=$(analyze steps "${dir#"$BENCH_DIR"/}")"
    done ;;
  e2) for _ in $(seq "$REPEATS"); do run e2 --workers "$2" --steps "$3"; done ;;
  e1) for _ in $(seq "$REPEATS"); do for r in 20 50 100; do run e1 --rate "$r"; done; done ;;
  e3) for _ in $(seq "$REPEATS"); do run e3 --submit-rate "$2"; done ;;
  e4)
    for _ in $(seq "$REPEATS"); do
      for f in c1 c2 c3 c4 c5 c6; do
        run e4 --fault "$f" --submit-rate "$2" || {
          log "e4 $f failed — re-creating the stack and running it again"
          "$ENV" down; "$ENV" up
          run e4 --fault "$f" --submit-rate "$2"
        }
      done
    done ;;
  *) die "usage: campaign.sh e2-pilots | e2 <workers> <steps> | e1 | e3 <rate> | e4 <rate>" ;;
esac
