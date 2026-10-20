#!/usr/bin/env bash
# The bench overlay changes Prometheus and nothing that alters behaviour (spec §4.1, §6). Prints service and key
# names only — a resolved config holds .env values, so it is written to a private temp dir and deleted.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
unset BENCH_EXTRA_COMPOSE   # the checks below are of the plain bench; the traced one is checked on its own
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

if out=$(python3 - "$tmp/base.json" "$tmp/bench.json" "$(IFS=,; echo "${BUILT_SERVICES[*]}")" "$BENCH_DIR/compose.bench.yml" <<'EOF'
import json, sys, yaml
base = json.load(open(sys.argv[1]))["services"]
bench = json.load(open(sys.argv[2]))["services"]
built = set(sys.argv[3].split(","))
# Services the overlay puts in profile "off" drop out of the bench's resolved config: the portal, the exporters (sp12
# task 15), Alertmanager (task 17) and Grafana (task 18). Nothing else may be switched off.
off = {"judge-portal", "node-exporter", "cadvisor", "identity-db-exporter", "problem-db-exporter", "submission-db-exporter",
       "redis-exporter", "kafka-exporter", "alertmanager", "grafana"}
problems = []
if set(bench) != set(base) - off:
    problems.append("service set: " + ", ".join(sorted((set(base) - off) ^ set(bench))))
overlay = yaml.safe_load(open(sys.argv[4]))["services"]
for name in sorted(n for n, x in overlay.items() if "profiles" in x):
    if name not in off or overlay[name] != {"profiles": ["off"]}:
        problems.append(f"{name}: profiles is only for the off services, as exactly {{profiles: [off]}}")
for name in sorted(set(bench) & set(base)):
    b, o = base[name], bench[name]
    allowed = {"command", "volumes"} if name == "prometheus" else ({"image", "pull_policy"} if name in built else set())
    diff = sorted(k for k in set(b) | set(o) if k not in allowed and b.get(k) != o.get(k))
    if diff:
        problems.append(f"{name}: {', '.join(diff)}")
print("; ".join(problems))
sys.exit(1 if problems else 0)
EOF
); then ok "the overlay changes only prometheus and the built services' image, and leaves judge-portal and the observability services out"
else bad "the overlay changes more than intended: $out"; fi

check "the built services run the live images (the base's resolved image), never pulled or built" \
  "all(s[n].get('image') == b[n].get('image') and s[n].get('pull_policy') == 'never' for n in '${BUILT_SERVICES[*]}'.split())"
check "prometheus accepts remote write and reads the generated config" \
  "'--web.enable-remote-write-receiver' in s['prometheus']['command'] and any(m['source'].endswith('/bench/.gen/prometheus.yml') and m['target'] == '/etc/prometheus/prometheus.yml' for m in s['prometheus']['volumes'])"
check "prometheus evaluates this checkout's alerts.yml (in a worktree, not the main checkout's)" \
  "any(__import__('os').path.normpath(m['source']) == '$(cd "$BENCH_DIR/.." && pwd)/alerts.yml' and m['target'] == '/etc/prometheus/alerts.yml' for m in s['prometheus']['volumes'])"
check "prometheus keeps its data volume" \
  "[m for m in s['prometheus']['volumes'] if m['target'] == '/prometheus'] == [m for m in b['prometheus']['volumes'] if m['target'] == '/prometheus']"
check "relative paths resolve against the main checkout (build context ../oj-submission-service)" \
  "s['submission-service']['build']['context'] == '$OJ_ROOT/oj-submission-service'"

if [ "$(diff "$BENCH_DIR/../prometheus.yml" "$BENCH_GEN/prometheus.yml" | grep -c '^>' || true)" = 2 ] \
  && grep -q '^  scrape_interval: 5s$' "$BENCH_GEN/prometheus.yml" && grep -q '^  evaluation_interval: 5s$' "$BENCH_GEN/prometheus.yml"; then
  ok "the generated prometheus.yml differs from the real one in the two global intervals only"
else bad "the generated prometheus.yml differs from the real one in the two global intervals only"; fi

# Sub-project 8 §3.1: BENCH_EXTRA_COMPOSE adds an overlay; compose.grpc-trace.yml traces submission-service's channel.
# Through SPRING_APPLICATION_JSON: an env var LOGGING_LEVEL_IO_GRPC_CHANNELLOGGER is lowercased by Spring Boot's binder
# (io.grpc.channellogger), and logger names are case-sensitive (final review I1).
traced() { python3 -c "import json,sys; e=json.loads(sys.argv[1] or '{}'); sys.exit(0 if e.get('logging',{}).get('level',{}).get('io.grpc.ChannelLogger') == 'TRACE' else 1)" "$1"; }
check "without BENCH_EXTRA_COMPOSE no service is traced" \
  "not any('io.grpc.ChannelLogger' in ((x.get('environment') or {}).get('SPRING_APPLICATION_JSON') or '') for x in s.values())"
if BENCH_EXTRA_COMPOSE=bench/compose.grpc-trace.yml bench_compose config --format json > "$tmp/traced.json" 2>/dev/null \
  && traced "$(python3 -c "import json; print(json.load(open('$tmp/traced.json'))['services']['submission-service']['environment'].get('SPRING_APPLICATION_JSON', ''))")" \
  && python3 -c "import json,sys; t=json.load(open('$tmp/traced.json'))['services']; sys.exit(0 if not any('io.grpc.ChannelLogger' in ((x.get('environment') or {}).get('SPRING_APPLICATION_JSON') or '') for n, x in t.items() if n != 'submission-service') else 1)"; then
  ok "BENCH_EXTRA_COMPOSE=bench/compose.grpc-trace.yml sets logger io.grpc.ChannelLogger (case kept) to TRACE in submission-service only"
else bad "BENCH_EXTRA_COMPOSE=bench/compose.grpc-trace.yml sets logger io.grpc.ChannelLogger (case kept) to TRACE in submission-service only"; fi
exit $fail
