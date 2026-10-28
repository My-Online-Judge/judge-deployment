#!/usr/bin/env bash
# k3s/base/data (sub-project 15): the stateful layer on K3s is the compose stack's, not a reinvention: Kafka's environment,
# the Postgres, Redis and MinIO command lines are compared with docker-compose.yml's; the generated files do not drift from
# their sources (kafka/, minio/); every container has a memory limit; Kafka is capped at 1 GiB with a 512M heap; the
# Secrets script builds the Secrets the pods read. Works on a copy of the .example files; prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# ---- the generated files equal what their generator makes -------------------------------------------------------------
for pair in "postgres:k3s/base/data/postgres.yaml" "init-scripts:k3s/base/data/init-scripts.yaml"; do
  target=${pair%%:*}; file=${pair#*:}
  if [[ ! -f $file ]]; then bad "$file exists"; continue; fi
  if diff <(python3 k3s/scripts/gen_data.py "$target") "$file" > "$tmp/diff"; then ok "$file is what gen_data.py $target makes"
  else bad "$file differs from the generator (python3 k3s/scripts/gen_data.py $target > $file):"; head -6 "$tmp/diff" | sed 's/^/     /'; fi
done

# ---- what is rendered, next to the compose file -----------------------------------------------------------------------
if ! kubectl kustomize k3s/overlays/local > "$tmp/rendered.yaml" 2> "$tmp/err"; then bad "the local overlay renders: $(head -3 "$tmp/err")"; exit 1; fi
docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/rendered.yaml" > "$tmp/rendered.json"
for f in .env*.example; do cp "$f" "$tmp/$f"; done
OJ_DEPLOY_DIR=$tmp bash scripts/local-stack.sh env > /dev/null
docker compose --project-directory "$tmp" -f "$PWD/docker-compose.yml" config --format json > "$tmp/compose.json"

OJ_DEPLOY_DIR=$tmp bash k3s/scripts/env-to-secrets.sh --dry-run | cut -d' ' -f1 > "$tmp/script-secrets.txt"

python3 - "$tmp" <<'PY' || fail=1
import json, sys
tmp = sys.argv[1]
objs = json.load(open(f"{tmp}/rendered.json"))
compose = json.load(open(f"{tmp}/compose.json"))["services"]
ok = lambda m: print("ok   " + m)
bad = lambda m: (print("FAIL " + m), globals().__setitem__("failed", True))
failed = False

def find(kind, name):
    return next((o for o in objs if o.get("kind") == kind and o["metadata"]["name"] == name), None)

def container(obj, cname=None):
    cs = obj["spec"]["template"]["spec"]["containers"]
    return next((c for c in cs if cname in (None, c["name"])), None)

def env(c):
    return {e["name"]: e.get("value") for e in c.get("env", []) if "value" in e}

# Kafka: the same broker configuration
kafka = find("StatefulSet", "kafka")
if not kafka:
    bad("a StatefulSet kafka")
else:
    k8s = {k: v for k, v in env(container(kafka)).items() if k.startswith("KAFKA_") or k == "CLUSTER_ID"}
    comp = {k: str(v).replace("$$", "$") for k, v in compose["kafka"]["environment"].items() if k.startswith("KAFKA_") or k == "CLUSTER_ID"}
    if k8s == comp: ok(f"Kafka's {len(comp)} KAFKA_* / CLUSTER_ID variables are compose's, value for value")
    else:
        diff = sorted(set(k8s.items()) ^ set(comp.items()))
        bad("Kafka's environment differs from compose: " + "; ".join(f"{k}={v}" for k, v in diff)[:300])
    res = container(kafka)["resources"]
    if k8s.get("KAFKA_HEAP_OPTS") == "-Xmx512M -Xms512M" and res["limits"]["memory"] == "1Gi":
        ok("Kafka: heap -Xmx512M -Xms512M and a 1Gi memory limit")
    else: bad("Kafka's heap or memory limit is not 512M / 1Gi")

# the command lines
def args(c): return (c.get("command") or []) + (c.get("args") or [])
for name, ckey in (("identity-db", "identity-db"), ("problem-db", "problem-db"), ("submission-db", "submission-db")):
    o = find("StatefulSet", name)
    if o and container(o)["args"] == compose[ckey]["command"]: ok(f"{name}: the postgres arguments are compose's (TLS, client certificates, pg_hba)")
    else: bad(f"{name}: postgres arguments differ from compose's")
r = find("StatefulSet", "redis")
if r and args(container(r)) == compose["redis"]["command"]: ok("redis: the command line is compose's (TLS only, AOF everysec)")
else: bad("redis: command line differs from compose's")
m = find("StatefulSet", "minio")
if m and container(m)["args"] == compose["minio"]["command"][0:] or (m and args(container(m))[-len(compose["minio"]["command"]):] == compose["minio"]["command"]):
    ok("minio: the server command is compose's")
else: bad("minio: server command differs from compose's")

# Services other pods reach by name, with the ports compose's services use
want = {"identity-db": {5432}, "problem-db": {5432}, "submission-db": {5432}, "kafka": {29092, 9093}, "redis": {6379}, "minio": {9000}}
for name, ports in want.items():
    s = find("Service", name)
    got = {p["port"] for p in s["spec"]["ports"]} if s else set()
    (ok if got == ports else bad)(f"Service {name} exposes {sorted(ports)}" + ("" if got == ports else f" (has {sorted(got)})"))

# every container of every workload: a memory limit; no service-link variables (a Service named kafka would put KAFKA_PORT
# in Kafka's environment and Kafka reads every KAFKA_* variable as configuration)
workloads = [o for o in objs if o.get("kind") in ("Deployment", "StatefulSet", "Job")]
nolimit, links = [], []
for o in workloads:
    pod = o["spec"]["template"]["spec"]
    for c in pod.get("containers", []) + pod.get("initContainers", []):
        if not c.get("resources", {}).get("limits", {}).get("memory"): nolimit.append(f'{o["metadata"]["name"]}/{c["name"]}')
    if pod.get("enableServiceLinks") is not False: links.append(o["metadata"]["name"])
(ok if not nolimit else bad)("every container has a memory limit" + (f": missing on {nolimit}" if nolimit else f" ({len(workloads)} workloads)"))
(ok if not links else bad)("no pod gets service-link variables (enableServiceLinks: false)" + (f": {links}" if links else ""))

# every Secret a pod reads is made by something: cert-manager (tls-*) or env-to-secrets.sh
made = {o["spec"]["secretName"] for o in objs if o.get("kind") == "Certificate"} | set(open(f"{tmp}/script-secrets.txt").read().split())
def secret_refs(pod):
    refs = set()
    for c in pod.get("containers", []) + pod.get("initContainers", []):
        refs |= {e["secretRef"]["name"] for e in c.get("envFrom", []) if "secretRef" in e}
        refs |= {e["valueFrom"]["secretKeyRef"]["name"] for e in c.get("env", []) if "secretKeyRef" in e.get("valueFrom", {})}
    for v in pod.get("volumes", []):
        if "secret" in v: refs.add(v["secret"]["secretName"])
        refs |= {src["secret"]["name"] for src in v.get("projected", {}).get("sources", []) if "secret" in src}
    return refs
dangling = sorted({(o["metadata"]["name"], r) for o in workloads for r in secret_refs(o["spec"]["template"]["spec"]) if r not in made})
(ok if not dangling else bad)("every Secret a pod reads is made by cert-manager or env-to-secrets.sh" + (f": missing {dangling}" if dangling else ""))

# hardening: what Pod Security `restricted` asks for, wherever the image allows it
weak = []
DATA = {"identity-db", "problem-db", "submission-db", "kafka", "redis", "minio", "kafka-init", "minio-init"}
for o in (w for w in workloads if w["metadata"]["name"] in DATA):
    pod = o["spec"]["template"]["spec"]
    sc = pod.get("securityContext", {})
    if sc.get("seccompProfile", {}).get("type") != "RuntimeDefault": weak.append(f'{o["metadata"]["name"]}: no RuntimeDefault seccomp profile')
    for c in pod.get("containers", []) + pod.get("initContainers", []):
        csc = c.get("securityContext", {})
        if csc.get("allowPrivilegeEscalation") is not False: weak.append(f'{o["metadata"]["name"]}/{c["name"]}: privilege escalation allowed')
        if csc.get("capabilities", {}).get("drop") != ["ALL"]: weak.append(f'{o["metadata"]["name"]}/{c["name"]}: capabilities not dropped')
        if not (csc.get("runAsNonRoot") or sc.get("runAsNonRoot")): weak.append(f'{o["metadata"]["name"]}/{c["name"]}: may run as root')
(ok if not weak else bad)("every pod: RuntimeDefault seccomp, no privilege escalation, every capability dropped, non-root" + (": " + "; ".join(weak[:4]) if weak else ""))

# Kafka's quorum voter is kafka:9093 and the broker is not Ready until it has joined: the Service must resolve before that
ks = find("Service", "kafka")
(ok if ks and ks["spec"].get("publishNotReadyAddresses") is True else bad)("Service kafka publishes not-ready addresses (the broker reaches its own controller through it before it is Ready)")

# the init Jobs
for job in ("kafka-init", "minio-init"):
    j = find("Job", job)
    (ok if j and j["spec"].get("ttlSecondsAfterFinished") else bad)(f"Job {job} exists and is removed after it finishes (a later apply runs it again)")
sys.exit(1 if failed else 0)
PY

# ---- the Secrets script -----------------------------------------------------------------------------------------------
if [[ -x k3s/scripts/env-to-secrets.sh ]]; then
  got=$(OJ_DEPLOY_DIR=$tmp bash k3s/scripts/env-to-secrets.sh --dry-run | sort)
  want=$(printf '%s\n' env-identity env-identity-db env-problem env-submission judge-token minio-init minio-problem minio-root minio-worker | sort)
  if [[ $(cut -d' ' -f1 <<< "$got") == "$want" ]]; then ok "env-to-secrets.sh makes env-identity, env-identity-db, env-problem, env-submission, judge-token, minio-init, minio-problem, minio-root, minio-worker"
  else bad "env-to-secrets.sh makes: $(cut -d' ' -f1 <<< "$got" | tr '\n' ' ')"; fi
  if ! grep -qE '[0-9a-f]{40}' <<< "$got"; then ok "--dry-run prints names and keys, never a value"; else bad "--dry-run printed something that looks like a secret"; fi
else bad "k3s/scripts/env-to-secrets.sh exists"; fi
exit $fail
