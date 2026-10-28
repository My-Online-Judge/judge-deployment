#!/usr/bin/env bash
# Observability on K3s (sub-project 15): Prometheus, Alertmanager, Grafana, kube-state-metrics and the database, Redis and Kafka
# exporters, run from the compose stack's own files (prometheus.yml, alerts.yml, alertmanager/, grafana/) so the two cannot
# drift. The judge pods come and go, so Prometheus finds them through the Kubernetes API; node-exporter and cAdvisor read the
# host (hostPath, hostPID) which the namespace's Pod Security level forbids, so they are not part of this base. Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
prom=prom/prometheus:v3.15.0
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

kubectl kustomize k3s/base > "$tmp/base.yaml" 2> "$tmp/err" || { bad "the base renders: $(head -3 "$tmp/err")"; exit 1; }
docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/base.yaml" > "$tmp/base.json"

# the generated files are what the generator makes now
for target in config exporters policies; do
  f=k3s/base/observability/$target.yaml
  if [[ -f $f ]] && python3 k3s/scripts/gen_observability.py "$target" | diff -q - "$f" > /dev/null; then ok "observability/$target.yaml is what gen_observability.py $target makes"
  else bad "observability/$target.yaml is what gen_observability.py $target makes"; fi
done

# the Prometheus ConfigMap's files, and both Prometheus configurations as JSON (no PyYAML needed)
python3 - "$tmp" <<'PY'
import json, sys
tmp = sys.argv[1]
for o in json.load(open(f"{tmp}/base.json")):
    if o.get("kind") == "ConfigMap" and o["metadata"]["name"] == "prometheus-config":
        for k, v in o["data"].items():
            open(f"{tmp}/{k}", "w").write(v)
PY
docker --context "$ctx" run --rm -i "$yq" -o=json '.' < prometheus.yml > "$tmp/compose-prom.json"
if [[ -f $tmp/prometheus.yml ]]; then docker --context "$ctx" run --rm -i "$yq" -o=json '.' < "$tmp/prometheus.yml" > "$tmp/k3s-prom.json"; else echo '{}' > "$tmp/k3s-prom.json"; fi

python3 - "$tmp" <<'PY' || fail=1
import json, os, re, sys
tmp = sys.argv[1]
base = json.load(open(f"{tmp}/base.json"))
failed = False
def ok(m): print("ok   " + m)
def bad(m):
    global failed
    failed = True
    print("FAIL " + m)
def check(cond, m, detail=""): (ok(m) if cond else bad(m + (": " + detail if detail else "")))
def find(kind, name): return next((o for o in base if o.get("kind") == kind and o["metadata"]["name"] == name), None)
def pod(d): return d["spec"]["template"]["spec"]

# ---- the Prometheus configuration: compose's, with the jobs that cannot exist on K3s changed ---------------------------
cm = find("ConfigMap", "prometheus-config")
check(cm is not None, "a ConfigMap prometheus-config")
cm = cm or {"data": {}}
compose = json.load(open(f"{tmp}/compose-prom.json"))
k3s = json.load(open(f"{tmp}/k3s-prom.json"))
cj = {j["job_name"]: j for j in compose["scrape_configs"]}
kj = {j["job_name"]: j for j in k3s.get("scrape_configs", [])}
check(set(kj) == (set(cj) - {"node-exporter", "cadvisor"}) | {"kube-state-metrics"},
      "the jobs are compose's without node-exporter and cadvisor (they read the host), plus kube-state-metrics", str(sorted(kj)))
same = [n for n in cj if n in kj and n not in ("judge-worker", "run-worker")]
check(all(kj[n] == cj[n] for n in same), "every other job is compose's, unchanged (same Service names, same ports, same mutual TLS)", str([n for n in same if kj[n] != cj[n]]))
for job, app in (("judge-worker", "judge"), ("run-worker", "run-judge")):
    j = kj.get(job, {})
    sd = (j.get("kubernetes_sd_configs") or [{}])[0]
    check(sd.get("role") == "pod" and sd.get("namespaces", {}).get("names") == ["oj"]
          and sd.get("selectors") == [{"role": "pod", "label": f"app={app}"}], f"{job}: the pods labelled app={app} in oj, found through the Kubernetes API", json.dumps(sd))
    check("dns_sd_configs" not in j, f"{job}: no DNS service discovery (a pod is not behind a name of its own)")
    tls = j.get("tls_config", {})
    check(j.get("scheme") == "https" and tls.get("server_name") == job and tls.get("cert_file") == "/etc/oj/tls/tls.crt",
          f"{job}: scraped over mutual TLS, verified as {job} (the targets are pod IPs)")
    rel = json.dumps(j.get("relabel_configs", []))
    check("__meta_kubernetes_pod_container_port_number" in rel and "9100" in rel, f"{job}: only the worker's metrics port 9100 is a target (not the sandbox's)")
    check(any(r.get("target_label") == "pod" for r in j.get("relabel_configs", [])), f"{job}: each target carries its pod name")
ksm = kj.get("kube-state-metrics", {})
check(ksm.get("static_configs") == [{"targets": ["kube-state-metrics:8080"]}] and ksm.get("scheme", "http") == "http",
      "kube-state-metrics: scraped on kube-state-metrics:8080 (plain http inside the cluster, like cAdvisor in compose)")
check(k3s.get("alerting") == compose["alerting"] and k3s.get("rule_files") == compose["rule_files"] and k3s.get("global") == compose["global"],
      "the global block, the rule file and Alertmanager's address are compose's")
check(cm["data"].get("alerts.yml") == open("alerts.yml").read(), "the rules in the ConfigMap are alerts.yml, byte for byte")

# ---- Alertmanager and Grafana take compose's files as they are ------------------------------------------------------------
am = (find("ConfigMap", "alertmanager-config") or {"data": {}})["data"]
check(am.get("render.sh") == open("alertmanager/render.sh").read() and am.get("telegram.tmpl") == open("alertmanager/telegram.tmpl").read(),
      "alertmanager-config holds alertmanager/render.sh and telegram.tmpl, byte for byte")
gp = (find("ConfigMap", "grafana-provisioning") or {"data": {}})["data"]
check(gp.get("datasources.yml") == open("grafana/provisioning/datasources/datasources.yml").read()
      and gp.get("dashboards.yml") == open("grafana/provisioning/dashboards/dashboards.yml").read(), "grafana-provisioning holds the datasource and dashboard providers, byte for byte")
dash = (find("ConfigMap", "grafana-dashboards") or {"data": {}})["data"]
want = {f: open(f"grafana/dashboards/{f}").read() for f in sorted(os.listdir("grafana/dashboards")) if f.endswith(".json")}
check(dash == want and want, "grafana-dashboards holds every file of grafana/dashboards, byte for byte", str(sorted(dash)))
ew = (find("ConfigMap", "exporter-web") or {"data": {}})["data"].get("exporter-web.yml", "")
check("client_auth_type: RequireAndVerifyClientCert" in ew and "client_ca_file: /etc/oj/tls/ca.crt" in ew, "exporter-web asks every scraper for a client certificate signed by the CA")

# ---- the workloads --------------------------------------------------------------------------------------------------
# name -> (image, service port, tls identity or None)
compose_images = {}
for line in open("docker-compose.yml"):
    m = re.match(r"\s+image: (\S+)", line)
    if m: compose_images[m.group(1).split(":")[0]] = m.group(1)
WORKLOADS = {
    "prometheus": ("prom/prometheus", 9090), "alertmanager": ("prom/alertmanager", 9093), "grafana": ("grafana/grafana-oss", 3000),
    "identity-db-exporter": ("prometheuscommunity/postgres-exporter", 9187), "problem-db-exporter": ("prometheuscommunity/postgres-exporter", 9187),
    "submission-db-exporter": ("prometheuscommunity/postgres-exporter", 9187), "redis-exporter": ("oliver006/redis_exporter", 9121),
    "kafka-exporter": ("danielqsj/kafka-exporter", 9308), "kube-state-metrics": ("registry.k8s.io/kube-state-metrics/kube-state-metrics", 8080),
}
for name, (image, port) in WORKLOADS.items():
    d, s = find("Deployment", name), find("Service", name)
    if not d: bad(f"a Deployment {name}"); continue
    p = pod(d); c = p["containers"][0]
    check(s and s["spec"]["selector"] == {"app": name} and [x["port"] for x in s["spec"]["ports"]] == [port], f"{name}: a Service on {port}")
    check(d["spec"]["selector"]["matchLabels"] == {"app": name} and d["spec"]["template"]["metadata"]["labels"]["app"] == name, f"{name}: labelled app={name}")
    check(re.fullmatch(r"[^:]+:v?\d+\.\d+\.\d+", c["image"]) and c["image"].startswith(image + ":"), f"{name}: image {image} at an exact version", c["image"])
    if image in compose_images:
        check(c["image"] == compose_images[image], f"{name}: the version compose runs", f'{c["image"]} vs {compose_images[image]}')
    check("memory" in c.get("resources", {}).get("limits", {}), f"{name}: a memory limit")
    sc = c.get("securityContext", {})
    check(sc.get("allowPrivilegeEscalation") is False and sc.get("readOnlyRootFilesystem") is True and sc.get("capabilities", {}).get("drop") == ["ALL"]
          and (p.get("securityContext", {}).get("runAsNonRoot") is True or sc.get("runAsNonRoot") is True), f"{name}: non-root, read-only root filesystem, no capabilities")
    check(p.get("enableServiceLinks") is False, f"{name}: no service-link variables")
    if name not in ("prometheus", "kube-state-metrics"):
        check(p.get("automountServiceAccountToken") is False, f"{name}: no ServiceAccount token")

# prometheus and kube-state-metrics are the only pods that talk to the Kubernetes API; what they may do is namespaced and read-only
for name in ("prometheus", "kube-state-metrics"):
    d = find("Deployment", name)
    sa = pod(d).get("serviceAccountName") if d else None
    check(sa == name and find("ServiceAccount", name), f"{name}: runs as its own ServiceAccount")
    check(find("ClusterRole", name) is None and find("ClusterRoleBinding", name) is None, f"{name}: no cluster-wide role")
    role, rb = find("Role", name), find("RoleBinding", name)
    verbs = {v for r in (role or {}).get("rules", []) for v in r["verbs"]}
    check(role and verbs <= {"get", "list", "watch"}, f"{name}: a Role that only reads", str(verbs))
    check(rb and rb["roleRef"]["name"] == name and any(x["name"] == name for x in rb["subjects"]), f"{name}: bound to its Role")
rules = {tuple(r["resources"]) for r in (find("Role", "prometheus") or {}).get("rules", [])}
check(rules == {("pods",)}, "prometheus reads pods and nothing else", str(rules))
ksm = find("Deployment", "kube-state-metrics")
check(ksm and "--namespaces=oj" in ksm["spec"]["template"]["spec"]["containers"][0].get("args", [])
      and any(a.startswith("--resources=") and a.split("=")[1] == "pods" for a in ksm["spec"]["template"]["spec"]["containers"][0].get("args", [])),
      "kube-state-metrics watches pods in oj only")

# Prometheus: its certificate, its data on a volume, one pod at a time (a ReadWriteOnce volume)
pr = find("Deployment", "prometheus")
if pr:
    p = pod(pr)
    check(p["volumes"] and any(v.get("secret", {}).get("secretName") == "tls-prometheus" for v in p["volumes"]), "prometheus: presents the identity prometheus (tls-prometheus)")
    check(any(v.get("persistentVolumeClaim") for v in p["volumes"]) and pr["spec"]["strategy"]["type"] == "Recreate", "prometheus: its data on a PersistentVolumeClaim, replaced by recreation")
    check(any(v.get("configMap", {}).get("name") == "prometheus-config" for v in p["volumes"]), "prometheus: reads prometheus-config")
for name in ("alertmanager", "grafana"):
    d = find("Deployment", name)
    check(d and any(v.get("persistentVolumeClaim") for v in pod(d)["volumes"]) and d["spec"]["strategy"]["type"] == "Recreate", f"{name}: its state on a PersistentVolumeClaim, replaced by recreation")
claims = {o["metadata"]["name"] for o in base if o.get("kind") == "PersistentVolumeClaim"}
used = {v["persistentVolumeClaim"]["claimName"] for o in base if o.get("kind") == "Deployment" for v in pod(o).get("volumes", []) if "persistentVolumeClaim" in v}
check(used <= claims, "every claim an observability pod mounts is declared", str(used - claims))

# secrets and environment
def env(d, key):
    return next((e for e in pod(d)["containers"][0].get("env", []) if e["name"] == key), None)
g = find("Deployment", "grafana")
e = env(g, "GF_SECURITY_ADMIN_PASSWORD") if g else None
check(e and e["valueFrom"]["secretKeyRef"] == {"name": "grafana-admin", "key": "GRAFANA_ADMIN_PASSWORD"}, "grafana: the admin password comes from the Secret grafana-admin")
for n in ("identity-db", "problem-db", "submission-db"):
    d = find("Deployment", f"{n}-exporter")
    pw = env(d, "DATA_SOURCE_PASS") if d else None
    uri = env(d, "DATA_SOURCE_URI") if d else None
    check(pw and pw["valueFrom"]["secretKeyRef"] == {"name": "pg-monitor", "key": "PG_MONITOR_PASSWORD"}, f"{n}-exporter: oj_monitor's password comes from the Secret pg-monitor")
    check(uri and uri["value"].startswith(f"{n}:5432/postgres?sslmode=verify-full") and env(d, "DATA_SOURCE_USER")["value"] == "oj_monitor",
          f"{n}-exporter: connects to {n} as oj_monitor, verifying the server and presenting its certificate")
am_d = find("Deployment", "alertmanager")
if am_d:
    c = pod(am_d)["containers"][0]
    check(c.get("command") == ["/bin/sh", "/etc/alertmanager/render.sh"], "alertmanager: starts through render.sh, as in compose")
    for k in ("ALERT_TELEGRAM_BOT_TOKEN", "ALERT_TELEGRAM_CHAT_ID"):
        ref = (env(am_d, k) or {}).get("valueFrom", {}).get("secretKeyRef", {})
        check(ref.get("name") == "alertmanager-telegram" and ref.get("key") == k and ref.get("optional") is True, f"alertmanager: {k} comes from the optional Secret alertmanager-telegram")

# the identities each pod presents exist (cert-manager Certificates)
certs = {o["spec"]["secretName"] for o in base if o.get("kind") == "Certificate"}
for name in ("prometheus", "identity-db-exporter", "problem-db-exporter", "submission-db-exporter", "redis-exporter", "kafka-exporter"):
    d = find("Deployment", name)
    sec = {v["secret"]["secretName"] for v in pod(d).get("volumes", []) if "secret" in v} if d else set()
    check(f"tls-{name}" in sec and f"tls-{name}" in certs, f"{name}: presents its own identity (tls-{name})")

# ---- the network: Prometheus may scrape, the exporters may reach what they read, nothing else is opened -------------------
pols = [o for o in base if o.get("kind") == "NetworkPolicy"]
def selects(sel, app):
    """Does a policy's podSelector pick the pods labelled app=<app> (a label, or an In expression over several)?"""
    if sel.get("matchLabels") == {"app": app}: return True
    return any(e["key"] == "app" and e["operator"] == "In" and app in e["values"] for e in sel.get("matchExpressions", [])) and not sel.get("matchLabels")
def reach(app, port, source):
    return any(selects(p["spec"]["podSelector"], app) and any(pp.get("port") == port for pp in r.get("ports", []))
               and any(f.get("podSelector", {}).get("matchLabels") == {"app": source} for f in r["from"])
               for p in pols for r in p["spec"].get("ingress", []))
scrape = [("identity-service", 8081), ("problem-service", 8081), ("submission-service", 8081), ("api-gateway", 8081), ("judge", 9100), ("run-judge", 9100),
          ("identity-db-exporter", 9187), ("problem-db-exporter", 9187), ("submission-db-exporter", 9187), ("redis-exporter", 9121),
          ("kafka-exporter", 9308), ("kube-state-metrics", 8080), ("alertmanager", 9093)]
missing = [f"{a}:{p}" for a, p in scrape if not reach(a, p, "prometheus")]
check(not missing, "Prometheus is admitted by everything it scrapes (and Alertmanager)", ", ".join(missing))
check(reach("prometheus", 9090, "grafana"), "Grafana is admitted by Prometheus (its datasource)")
reads = [("identity-db", 5432, "identity-db-exporter"), ("problem-db", 5432, "problem-db-exporter"), ("submission-db", 5432, "submission-db-exporter"),
         ("redis", 6379, "redis-exporter"), ("kafka", 29092, "kafka-exporter")]
missing = [f"{a}:{p}" for a, p, s in reads if not reach(a, p, s)]
check(not missing, "each exporter is admitted by the one thing it reads", ", ".join(missing))
check(not reach("identity-db", 5432, "problem-db-exporter") and not reach("kafka", 29092, "prometheus"), "an exporter reaches only its own target, and Prometheus does not reach Kafka")
sys.exit(1 if failed else 0)
PY

# ---- promtool accepts what the pod will read ------------------------------------------------------------------------------
if [[ -f $tmp/prometheus.yml ]]; then
  fixture=$tmp/tls; mkdir "$fixture"; touch "$fixture"/{ca.crt,tls.crt,tls.key}; chmod 755 "$fixture"; chmod 644 "$fixture"/* "$tmp/prometheus.yml" "$tmp/alerts.yml"
  if out=$(docker --context "$ctx" run --rm --network none --entrypoint promtool -v "$tmp/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
       -v "$tmp/alerts.yml:/etc/prometheus/alerts.yml:ro" -v "$fixture:/etc/oj/tls:ro" "$prom" check config /etc/prometheus/prometheus.yml 2>&1); then
    ok "promtool accepts the ConfigMap's prometheus.yml with its rules"
  else bad "promtool check config: $out"; fi
else bad "promtool check config (no prometheus.yml in the ConfigMap)"; fi
exit $fail
