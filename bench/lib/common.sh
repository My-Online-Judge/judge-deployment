# Shared by every bench script (sub-project 5): where things are, and the one way to talk to the oj-bench stack.
# Sourced, never executed. Never prints a value from .env.
BENCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The checkout that owns the .env files and sits beside the sibling repositories. In a worktree it is the main
# checkout, so ./alerts.yml, ../judge-server/log and the build contexts resolve as they do for the live stack.
DEPLOY_DIR=$(dirname "$(git -C "$BENCH_DIR" rev-parse --path-format=absolute --git-common-dir)")
OJ_ROOT=$(dirname "$DEPLOY_DIR")
BENCH_PROJECT=oj-bench
LIVE_PROJECT=judge-deployment
BENCH_GEN="$BENCH_DIR/.gen"
K6_IMAGE='grafana/k6:2.3.0@sha256:9c2dee7f8ed74d317e4027c06a10f169b625638189de8d4555d0b3486a5aeb34'
ANALYZE_IMAGE='oj-bench-analyze:1'
PROM_URL='http://127.0.0.1:9090'
MAX_SUBMIT_RATE=18   # = maxSubmitRate() in k6/lib/pure.js: 200 users, 10 s cooldown, 10 % margin
# Built from source in production; the overlay runs the live stack's images of these, never a rebuild.
BUILT_SERVICES=(submission-service identity-service problem-service api-gateway judge-worker)

die() { echo "bench: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

bench_compose() {
  BENCH_DIR="$BENCH_DIR" docker compose -p "$BENCH_PROJECT" --project-directory "$DEPLOY_DIR" \
    -f "$BENCH_DIR/../docker-compose.yml" -f "$BENCH_DIR/compose.bench.yml" "$@"
}

ensure_analyze_image() {
  docker image inspect "$ANALYZE_IMAGE" >/dev/null 2>&1 || docker build -q -t "$ANALYZE_IMAGE" "$BENCH_DIR/analyze" >/dev/null
}

analyze() { # analyze <oj_analyze args…> — paths relative to bench/
  ensure_analyze_image
  docker run --rm --network oj-net --user "$(id -u):$(id -g)" -v "$BENCH_DIR:/bench" -w /bench "$ANALYZE_IMAGE" \
    python -m oj_analyze "$@"
}
