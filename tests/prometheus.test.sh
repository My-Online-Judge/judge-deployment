#!/usr/bin/env bash
# promtool accepts prometheus.yml with the rules it loads, and the judge-worker replicas are scraped one by one
# through DNS (sub-project 6 §3.1). Prints key names only.
set -euo pipefail
cd "$(dirname "$0")/.."
# The scrape jobs present Prometheus's certificate from /etc/oj/tls (the tls volume in compose). promtool only checks
# that the files exist, so it gets a directory of empty stand-ins.
tls_fixture=$(mktemp -d); trap 'rm -rf "$tls_fixture"' EXIT
touch "$tls_fixture/ca.crt" "$tls_fixture/tls.crt" "$tls_fixture/tls.key"
chmod 755 "$tls_fixture"; chmod 644 "$tls_fixture"/*   # promtool runs as nobody
docker run --rm --network none --entrypoint promtool \
  -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "$PWD/alerts.yml:/etc/prometheus/alerts.yml:ro" \
  -v "$tls_fixture:/etc/oj/tls:ro" \
  prom/prometheus:v3.15.0 check config /etc/prometheus/prometheus.yml
# The alert rules' unit tests, with alerts.yml where each test file's rule_files expects it.
for t in alerts_test.yml alerts_fast_test.yml; do
  docker run --rm --network none --entrypoint promtool \
    -v "$PWD/alerts.yml:/etc/prometheus/alerts.yml:ro" -v "$PWD/$t:/etc/prometheus/$t:ro" \
    prom/prometheus:v3.15.0 test rules "/etc/prometheus/$t"
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
tls = {"ca_file": "/etc/oj/tls/ca.crt", "cert_file": "/etc/oj/tls/tls.crt", "key_file": "/etc/oj/tls/tls.key"}
ok3 = all(jobs.get(n, {}).get("scheme") == "https" and jobs.get(n, {}).get("tls_config") == tls
          for n in ("identity-service", "problem-service", "submission-service", "api-gateway"))
print(("ok   " if ok3 else "FAIL ") + "prometheus scrapes the identity, problem, submission and api-gateway actuators over mutual TLS")
# The worker replicas are scraped by IP (DNS-SD): without server_name the judge-worker certificate fails verification.
worker = jobs.get("judge-worker", {})
ok4 = worker.get("scheme") == "https" and worker.get("tls_config") == dict(tls, server_name="judge-worker")
print(("ok   " if ok4 else "FAIL ") + "prometheus scrapes the judge-worker replicas over mutual TLS, verifying the name judge-worker")
# The exporters (sp12 task 15): one job per service, named after it, target <service>:<port>. All over mutual TLS with
# Prometheus's certificate, except cAdvisor, which has no TLS (plain HTTP on oj-net, like SP10's operator UIs).
exporters = {"node-exporter": 9100, "cadvisor": 8080, "identity-db-exporter": 9187, "problem-db-exporter": 9187,
             "submission-db-exporter": 9187, "redis-exporter": 9121, "kafka-exporter": 9308}
ok5 = all(jobs.get(n, {}).get("static_configs") == [{"targets": [f"{n}:{p}"]}] for n, p in exporters.items())
print(("ok   " if ok5 else "FAIL ") + "prometheus has one job per exporter, named after the service, target <service>:<port>")
ok6 = all(jobs.get(n, {}).get("scheme") == "https" and jobs.get(n, {}).get("tls_config") == tls for n in exporters if n != "cadvisor") \
  and jobs.get("cadvisor", {}).get("scheme", "http") == "http" and "tls_config" not in jobs.get("cadvisor", {"tls_config": None})
print(("ok   " if ok6 else "FAIL ") + "prometheus scrapes the six TLS exporters over mutual TLS and cadvisor over plain HTTP")
sys.exit(0 if ok and ok2 and ok3 and ok4 and ok5 and ok6 else 1)
EOF
