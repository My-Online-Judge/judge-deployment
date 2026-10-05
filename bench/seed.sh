#!/usr/bin/env bash
# Seeds a fresh oj-bench stack (spec §4.3) through the API: users, problems, verified reference solutions;
# --history adds 2 judged submissions per user (E1). Writes .gen/users.json for the experiment scripts.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
history=0
[ "${1:-}" = "--history" ] && history=1
mkdir -p "$BENCH_GEN/data"
for slug in bench-ab bench-sum; do
  rm -f "$BENCH_GEN/data/$slug.zip"
  (cd "$BENCH_DIR/data/$slug" && python3 -m zipfile -c "$BENCH_GEN/data/$slug.zip" 1.in 1.out 2.in 2.out 3.in 3.out 4.in 4.out 5.in 5.out)
done
rm -f "$BENCH_GEN/users.json" "$BENCH_GEN/seed-report.json"
log "seeding (history=$history)"
docker run --rm --network oj-net --user "$(id -u):$(id -g)" \
  -v "$BENCH_DIR/k6:/scripts:ro" -v "$BENCH_DIR/data:/data:ro" -v "$BENCH_GEN:/gen" \
  -e HISTORY="$history" "$K6_IMAGE" run --quiet /scripts/seed.js
[ -s "$BENCH_GEN/users.json" ] || die "the seed did not write users.json (see the k6 error above)"
log "seeded: $(jq length "$BENCH_GEN/users.json") users; reference verdicts $(jq -c .verdicts "$BENCH_GEN/seed-report.json")"
