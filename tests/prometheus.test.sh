#!/usr/bin/env bash
# promtool accepts prometheus.yml with the rules it loads, and the judge-worker replicas are scraped one by one
# through DNS (sub-project 6 §3.1). Prints key names only.
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm --network none --entrypoint promtool \
  -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "$PWD/alerts.yml:/etc/prometheus/alerts.yml:ro" \
  prom/prometheus:v3.1.0 check config /etc/prometheus/prometheus.yml
# The alert rules' unit tests, with alerts.yml where each test file's rule_files expects it.
for t in alerts_test.yml alerts_fast_test.yml; do
  docker run --rm --network none --entrypoint promtool \
    -v "$PWD/alerts.yml:/etc/prometheus/alerts.yml:ro" -v "$PWD/$t:/etc/prometheus/$t:ro" \
    prom/prometheus:v3.1.0 test rules "/etc/prometheus/$t"
done
python3 - <<'EOF'
import sys, yaml
jobs = {j["job_name"]: j for j in yaml.safe_load(open("prometheus.yml"))["scrape_configs"]}
sd = (jobs.get("judge-worker", {}).get("dns_sd_configs") or [{}])[0]
ok = sd.get("names") == ["judge-worker"] and sd.get("type") == "A" and sd.get("port") == 9100
print(("ok   " if ok else "FAIL ") + "prometheus scrapes every judge-worker replica on :9100, found through DNS")
prom = (jobs.get("prometheus", {}).get("static_configs") or [{}])[0].get("targets")
ok2 = prom == ["localhost:9090"]
print(("ok   " if ok2 else "FAIL ") + "prometheus scrapes itself (process_start_time_seconds guards the *Down rules)")
sys.exit(0 if ok and ok2 else 1)
EOF
