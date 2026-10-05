#!/usr/bin/env bash
# Writes .gen/prometheus.yml: prometheus.yml with the global scrape and evaluation intervals at 5 s. Generated,
# never hand-copied, so the bench scrapes exactly the jobs production scrapes.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
src="$BENCH_DIR/../prometheus.yml"
out="$BENCH_GEN/prometheus.yml"
mkdir -p "$BENCH_GEN"
sed -E 's/^(  (scrape|evaluation)_interval:) 15s$/\1 5s/' "$src" > "$out"
changed=$(diff "$src" "$out" | grep -c '^>' || true)
[ "$changed" -eq 2 ] || die "expected to change the 2 global interval lines of prometheus.yml, changed $changed"
