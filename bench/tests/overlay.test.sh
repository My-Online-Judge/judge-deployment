#!/usr/bin/env bash
# The bench overlay changes Prometheus and nothing that alters behaviour (spec §4.1, §6). Prints service and key
# names only — a resolved config holds .env values, so it is written to a private temp dir and deleted.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
tmp=$(mktemp -d); chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { # check <description> <python expression over b = base services, s = bench services>
  if python3 -c "import json,sys; b=json.load(open('$tmp/base.json'))['services']; s=json.load(open('$tmp/bench.json'))['services']; sys.exit(0 if ($2) else 1)"; then ok "$1"; else bad "$1"; fi
}

"$BENCH_DIR/gen-prometheus.sh"
docker compose -p "$BENCH_PROJECT" --project-directory "$DEPLOY_DIR" -f "$BENCH_DIR/../docker-compose.yml" \
  config --format json > "$tmp/base.json"
bench_compose config --format json > "$tmp/bench.json"

if out=$(python3 - "$tmp/base.json" "$tmp/bench.json" "$(IFS=,; echo "${BUILT_SERVICES[*]}")" <<'EOF'
import json, sys
base = json.load(open(sys.argv[1]))["services"]
bench = json.load(open(sys.argv[2]))["services"]
built = set(sys.argv[3].split(","))
problems = []
if set(bench) != set(base) - {"judge-portal"}:
    problems.append("service set: " + ", ".join(sorted(set(base) ^ set(bench))))
for name in sorted(set(bench) & set(base)):
    b, o = base[name], bench[name]
    allowed = {"command", "volumes"} if name == "prometheus" else ({"image", "pull_policy"} if name in built else set())
    diff = sorted(k for k in set(b) | set(o) if k not in allowed and b.get(k) != o.get(k))
    if diff:
        problems.append(f"{name}: {', '.join(diff)}")
print("; ".join(problems))
sys.exit(1 if problems else 0)
EOF
); then ok "the overlay changes only prometheus and the built services' image, and leaves judge-portal out"
else bad "the overlay changes more than intended: $out"; fi

check "the built services run the live images, never pulled or built" \
  "all(s[n].get('image') == f'judge-deployment-{n}:latest' and s[n].get('pull_policy') == 'never' for n in '${BUILT_SERVICES[*]}'.split())"
check "prometheus accepts remote write and reads the generated config" \
  "'--web.enable-remote-write-receiver' in s['prometheus']['command'] and any(m['source'].endswith('/bench/.gen/prometheus.yml') and m['target'] == '/etc/prometheus/prometheus.yml' for m in s['prometheus']['volumes'])"
check "prometheus keeps its other mounts (alerts, data volume)" \
  "[m for m in s['prometheus']['volumes'] if m['target'] != '/etc/prometheus/prometheus.yml'] == [m for m in b['prometheus']['volumes'] if m['target'] != '/etc/prometheus/prometheus.yml']"
check "relative paths resolve against the main checkout (../judge-server/log)" \
  "any(m.get('source') == '$OJ_ROOT/judge-server/log' for m in s['judge-server'].get('volumes', []))"

if [ "$(diff "$BENCH_DIR/../prometheus.yml" "$BENCH_GEN/prometheus.yml" | grep -c '^>' || true)" = 2 ] \
  && grep -q '^  scrape_interval: 5s$' "$BENCH_GEN/prometheus.yml" && grep -q '^  evaluation_interval: 5s$' "$BENCH_GEN/prometheus.yml"; then
  ok "the generated prometheus.yml differs from the real one in the two global intervals only"
else bad "the generated prometheus.yml differs from the real one in the two global intervals only"; fi
exit $fail
