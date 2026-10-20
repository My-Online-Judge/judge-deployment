#!/usr/bin/env bash
# Grafana (sp12 task 18): the provisioned dashboards have the agreed uids, titles and panels; every panel query is valid
# PromQL for a real Prometheus; a throwaway Grafana loads the provisioning and lists the dashboards. The compose checks
# (port, password variable, mem_limit) are in tests/compose.test.sh. Needs docker and jq. Prints no secret: the throwaway
# admin password is random and goes to curl through a config on stdin.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
d=grafana/dashboards

# titles: <file> <uid> <title> <panel title>...
want() {
  local f=$1 uid=$2 title=$3; shift 3
  [[ -f $d/$f ]] || { bad "$f exists"; return; }
  if [[ $(jq -r '[.uid, .title, (.schemaVersion|tostring)] | join("|")' "$d/$f") == "$uid|$title|39" ]]; then ok "$f: uid $uid, title \"$title\", schemaVersion 39"; else bad "$f: uid $uid, title \"$title\", schemaVersion 39"; fi
  local p
  for p in "$@"; do
    if jq -e --arg p "$p" 'any(.panels[]; .title == $p)' "$d/$f" >/dev/null; then ok "$f panel \"$p\""; else bad "$f panel \"$p\""; fi
  done
}
want oj-overview.json oj-overview "OJ Overview" "Verdicts per minute by status" "Judge latency p50 / p95" "Queue depth" "5xx rate per service" "p95 latency per service" "Active alerts"
want infrastructure.json oj-infrastructure "Infrastructure" "Host CPU" "Host memory" "Host disk free" "Container CPU" "Container memory" "Postgres connections" "Redis memory" "Kafka consumer lag"
want jvm.json oj-jvm "JVM" "Heap used" "GC pause time" "Live threads"
shopt -s nullglob
files=("$d"/*.json)
((${#files[@]} == 3)) && ok "exactly 3 dashboard files" || bad "exactly 3 dashboard files (${#files[@]})"
if [[ $(jq -r '.templating.list[] | select(.name == "job") | .query.query' $d/jvm.json 2>/dev/null) == "label_values(jvm_memory_used_bytes, job)" ]]; then ok "jvm.json: variable job = label_values(jvm_memory_used_bytes, job)"; else bad "jvm.json: variable job = label_values(jvm_memory_used_bytes, job)"; fi
if ((${#files[@]})) && [[ $(jq -r '.panels[].targets[]? | .datasource.uid' "${files[@]}" | sort -u) == prometheus ]]; then ok "every target uses datasource uid prometheus"; else bad "every target uses datasource uid prometheus"; fi
grep -q '^  - name: Prometheus' grafana/provisioning/datasources/datasources.yml && grep -q 'uid: prometheus' grafana/provisioning/datasources/datasources.yml \
  && grep -q 'url: http://prometheus:9090' grafana/provisioning/datasources/datasources.yml && grep -q 'isDefault: true' grafana/provisioning/datasources/datasources.yml \
  && ok "datasource prometheus: uid prometheus, http://prometheus:9090, default" || bad "datasource prometheus: uid prometheus, http://prometheus:9090, default"
grep -q 'path: /var/lib/grafana/dashboards' grafana/provisioning/dashboards/dashboards.yml && ok "dashboard provider reads /var/lib/grafana/dashboards" || bad "dashboard provider reads /var/lib/grafana/dashboards"

((${#files[@]} == 3)) || { echo "no point starting Prometheus and Grafana without the 3 dashboard files"; exit 1; }

# ---- throwaway Prometheus and Grafana on a scratch network ----
tag=sp12t18-$$
net=$tag-net
cleanup() { docker rm -f "$tag-prom" "$tag-graf" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create "$net" >/dev/null
docker run -d --name "$tag-prom" --network "$net" --network-alias prometheus --memory 256m prom/prometheus:v3.1.0 >/dev/null
ip_of() { docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$1"; }
prom_ip=$(ip_of "$tag-prom")
for _ in $(seq 30); do curl -fsS "http://$prom_ip:9090/-/ready" >/dev/null 2>&1 && break; sleep 1; done

bad_n=0; n=0
while IFS= read -r expr; do
  n=$((n + 1))
  q=${expr//\$__rate_interval/1m}; q=${q//\$job/.*}
  if [[ $(curl -s "http://$prom_ip:9090/api/v1/query" --data-urlencode "query=$q" | jq -r .status) != success ]]; then bad "query rejected by Prometheus: $q"; bad_n=$((bad_n + 1)); fi
done < <(jq -r '.panels[].targets[]?.expr' "${files[@]}")
((n == 18 && bad_n == 0)) && ok "all $n panel queries return status success on prom/prometheus:v3.1.0"
((n != 18)) && bad "expected 18 panel queries, found $n"

pw=$(openssl rand -hex 12)
docker run -d --name "$tag-graf" --network "$net" --memory 256m -e "GF_SECURITY_ADMIN_PASSWORD=$pw" \
  -e GF_USERS_ALLOW_SIGN_UP=false -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false -e GF_PLUGINS_PREINSTALL_DISABLED=true \
  -v "$PWD/grafana/provisioning:/etc/grafana/provisioning:ro" -v "$PWD/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  grafana/grafana-oss:12.0.2 >/dev/null
graf_ip=$(ip_of "$tag-graf")
gcurl() { curl -fsS -K <(printf 'user = "admin:%s"\n' "$pw") "$@"; }
uids=
for _ in $(seq 60); do
  uids=$(gcurl "http://$graf_ip:3000/api/search?type=dash-db" 2>/dev/null | jq -r '[.[].uid] | sort | join(",")' 2>/dev/null || true)
  [[ $uids == oj-infrastructure,oj-jvm,oj-overview ]] && break
  sleep 1
done
if [[ $uids == oj-infrastructure,oj-jvm,oj-overview ]]; then ok "throwaway Grafana lists oj-infrastructure, oj-jvm, oj-overview within 60 s"; else bad "throwaway Grafana lists the 3 dashboards (got: ${uids:-none})"; fi
if [[ $(gcurl "http://$graf_ip:3000/api/datasources" | jq -r '[.[] | .uid + ":" + (.isDefault|tostring)] | join(",")') == prometheus:true ]]; then ok "the only datasource is prometheus, the default (no Jaeger: README)"; else bad "the only datasource is prometheus, the default"; fi
if [[ $(gcurl "http://$graf_ip:3000/api/datasources/uid/prometheus/health" | jq -r .status) == OK ]]; then ok "Grafana reaches Prometheus (datasource health OK)"; else bad "Grafana reaches Prometheus (datasource health OK)"; fi
body='{"queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"prometheus"},"expr":"up","instant":true}],"from":"now-5m","to":"now"}'
if [[ $(gcurl -H 'Content-Type: application/json' -d "$body" "http://$graf_ip:3000/api/ds/query" | jq -r '.results.A.status') == 200 ]]; then ok "a panel-style query through /api/ds/query answers 200"; else bad "a panel-style query through /api/ds/query answers 200"; fi
if gcurl "http://$graf_ip:3000/api/dashboards/uid/oj-jvm" | jq -e '.dashboard.templating.list[0].name == "job"' >/dev/null; then ok "oj-jvm is served with its job variable"; else bad "oj-jvm is served with its job variable"; fi
exit $fail
