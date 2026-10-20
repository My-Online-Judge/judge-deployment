# Shared by every bench script (sub-project 5): where things are, and the one way to talk to the oj-bench stack.
# Sourced, never executed. Never prints a value from .env.
BENCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The checkout that owns the .env files and sits beside the sibling repositories. In a worktree it is the main
# checkout, so ./alerts.yml and the ../ build contexts resolve as they do for the live stack.
DEPLOY_DIR=$(dirname "$(git -C "$BENCH_DIR" rev-parse --path-format=absolute --git-common-dir)")
OJ_ROOT=$(dirname "$DEPLOY_DIR")
BENCH_PROJECT=oj-bench
LIVE_PROJECT=judge-deployment
BENCH_GEN="$BENCH_DIR/.gen"
K6_IMAGE='grafana/k6:2.3.0@sha256:9c2dee7f8ed74d317e4027c06a10f169b625638189de8d4555d0b3486a5aeb34'
ANALYZE_IMAGE='oj-bench-analyze:1'
PROM_URL='http://127.0.0.1:9090'
# k6 reaches the API through the edge (https://edge), whose certificate comes from our private CA, and k6 (Go) reads
# SSL_CERT_FILE. The CA certificate is bind-mounted from the deployment's pki/out (0644): k6 runs as the host user, and
# the tls volume's per-identity directories are root-owned 0700, so a volume subpath would be unreadable to it.
K6_TLS=(-v "$DEPLOY_DIR/pki/out/ca/ca.crt:/etc/oj/ca.crt:ro" -e SSL_CERT_FILE=/etc/oj/ca.crt)
# The CA for host-side curl (bench/probe.sh): $OJ_CA, else this checkout's pki/out, else the main checkout's.
if [ -n "${OJ_CA:-}" ]; then :
elif [ -f "$BENCH_DIR/../pki/out/ca/ca.crt" ]; then OJ_CA="$BENCH_DIR/../pki/out/ca/ca.crt"
else OJ_CA="$DEPLOY_DIR/pki/out/ca/ca.crt"; fi
MAX_SUBMIT_RATE=18   # = maxSubmitRate() in k6/lib/pure.js: 200 users, 10 s cooldown, 10 % margin
# Built from source in production; the overlay runs the live stack's images of these, never a rebuild.
BUILT_SERVICES=(submission-service identity-service problem-service api-gateway judge-worker)

die() { echo "bench: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

bench_compose() { # BENCH_EXTRA_COMPOSE=<file> adds one more overlay (relative to the checkout), e.g. bench/compose.grpc-trace.yml
  local extra=()
  if [ -n "${BENCH_EXTRA_COMPOSE:-}" ]; then
    case "$BENCH_EXTRA_COMPOSE" in /*) extra=(-f "$BENCH_EXTRA_COMPOSE") ;; *) extra=(-f "$BENCH_DIR/../$BENCH_EXTRA_COMPOSE") ;; esac
  fi
  BENCH_DIR="$BENCH_DIR" docker compose -p "$BENCH_PROJECT" --project-directory "$DEPLOY_DIR" \
    -f "$BENCH_DIR/../docker-compose.yml" -f "$BENCH_DIR/compose.bench.yml" "${extra[@]}" "$@"
}

ensure_analyze_image() {
  docker image inspect "$ANALYZE_IMAGE" >/dev/null 2>&1 || docker build -q -t "$ANALYZE_IMAGE" "$BENCH_DIR/analyze" >/dev/null
}

analyze() { # analyze <oj_analyze args…> — paths relative to bench/
  ensure_analyze_image
  docker run --rm --network oj-net --user "$(id -u):$(id -g)" -v "$BENCH_DIR:/bench" -w /bench "$ANALYZE_IMAGE" \
    python -m oj_analyze "$@"
}
