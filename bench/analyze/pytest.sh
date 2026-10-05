#!/usr/bin/env bash
# Runs pytest in the pinned analysis image (bench/analyze/Dockerfile), as the host user.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
ensure_analyze_image
if [ $# -eq 0 ]; then set -- tests; [ -d "$BENCH_DIR/analyze/tests" ] && set -- "$@" analyze/tests; fi
docker run --rm --user "$(id -u):$(id -g)" -v "$BENCH_DIR:/bench" -w /bench "$ANALYZE_IMAGE" \
  python -m pytest -q -p no:cacheprovider "$@"
