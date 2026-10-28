#!/usr/bin/env bash
# k3s/base/judge (sub-project 15): the Judge Pod pairs a sandbox with a worker, one to one. The worker's environment and the
# sandbox's hardening are compared with docker-compose.yml's; the sandbox is a native sidecar (it starts first and stops last,
# so a judgement in flight finishes); the pod has no ServiceAccount token and may reach only what the worker needs; the local
# overlay swaps the sandbox for the mock. Works on a copy of the .example files; prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

if diff <(python3 k3s/scripts/gen_services.py judge) k3s/base/judge/judge.yaml > "$tmp/diff" 2>&1; then ok "k3s/base/judge/judge.yaml is what gen_services.py judge makes"
else bad "k3s/base/judge/judge.yaml differs from the generator (python3 k3s/scripts/gen_services.py judge > k3s/base/judge/judge.yaml):"; head -4 "$tmp/diff" | sed 's/^/     /'; fi

for overlay in base overlays/local; do
  kubectl kustomize "k3s/$overlay" > "$tmp/$(basename "$overlay").yaml" 2> "$tmp/err" || { bad "k3s/$overlay renders: $(head -3 "$tmp/err")"; exit 1; }
  docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/$(basename "$overlay").yaml" > "$tmp/$(basename "$overlay").json"
done
for f in .env*.example; do cp "$f" "$tmp/$f"; done
OJ_DEPLOY_DIR=$tmp bash scripts/local-stack.sh env > /dev/null
docker compose --project-directory "$tmp" -f "$PWD/docker-compose.yml" config --format json > "$tmp/compose.json"

python3 - "$tmp" <<'PY' || fail=1
import json, sys
tmp = sys.argv[1]
base = json.load(open(f"{tmp}/base.json"))
local = json.load(open(f"{tmp}/local.json"))
compose = json.load(open(f"{tmp}/compose.json"))["services"]
failed = False
def ok(m): print("ok   " + m)
def bad(m):
    global failed
    failed = True
    print("FAIL " + m)
def check(cond, m, detail=""): (ok(m) if cond else bad(m + (": " + detail if detail else "")))
def find(objs, kind, name): return next((o for o in objs if o.get("kind") == kind and o["metadata"]["name"] == name), None)
def pod(o): return o["spec"]["template"]["spec"]
def literal(c): return {e["name"]: e["value"] for e in c.get("env", []) if "value" in e}
def names(c): return {e["name"] for e in c.get("env", [])}

PAIRS = (("judge", "judge-worker", "tls-judge-worker"), ("run-judge", "run-worker", "tls-run-worker"))
EXTRA = {"judge": {"POD_NAME", "CONSUMER_GROUP", "MAX_POLL_INTERVAL_MS"}, "run-judge": {"POD_NAME"}}
for name, comp_name, worker_tls in PAIRS:
    d = find(base, "Deployment", name)
    if not d: bad(f"a Deployment {name}"); continue
    p = pod(d)
    sidecars = {c["name"]: c for c in p.get("initContainers", [])}
    sandbox, worker = sidecars.get("sandbox"), next((c for c in p["containers"] if c["name"] == "worker"), None)
    check(sandbox and sandbox.get("restartPolicy") == "Always" and worker and len(p["containers"]) == 1,
          f"{name}: the sandbox is a native sidecar (starts first, stops last) and the worker the only main container")
    if not (sandbox and worker): continue
    # the worker: compose's environment, plus what a pod adds
    comp_env = {k: str(v) for k, v in compose[comp_name]["environment"].items()}
    have = names(worker)
    missing, extra = sorted(set(comp_env) - have), sorted(have - set(comp_env) - EXTRA[name])
    check(not missing and not extra, f"{name}: the worker has compose's {len(comp_env)} variables (plus {sorted(EXTRA[name])})", f"missing {missing}, not allowed {extra}")
    lit = literal(worker)
    differ = sorted(k for k, v in lit.items() if k in comp_env and k != "JUDGE_SERVER_URL" and comp_env[k] != v)
    check(not differ, f"{name}: every literal value is compose's", ", ".join(f"{k}: {lit[k]!r} vs {comp_env[k]!r}" for k in differ))
    check(lit.get("JUDGE_SERVER_URL") == "https://localhost:8080", f"{name}: the worker calls its own sandbox over mutual TLS on localhost")
    pn = next((e for e in worker["env"] if e["name"] == "POD_NAME"), {})
    check(pn.get("valueFrom", {}).get("fieldRef", {}).get("fieldPath") == "metadata.name", f"{name}: POD_NAME comes from the Downward API")
    if name == "judge":
        check(lit.get("CONSUMER_GROUP") == "judge-workers" and lit.get("MAX_POLL_INTERVAL_MS") == "600000", "judge: consumer group judge-workers, 10 minute poll interval")
        check(12003 in p["securityContext"].get("supplementalGroups", []), "judge: the worker is in group 12003 (the checker's group), as compose's group_add")
    # the sandbox: compose's image, command environment and hardening
    cs = compose["judge-server"]
    sc = sandbox["securityContext"]
    check(sandbox["image"] == cs["image"], f"{name}: the sandbox image is compose's, pinned by digest")
    check(sc.get("privileged") in (None, False) and sc.get("allowPrivilegeEscalation") is False and sc["capabilities"]["drop"] == ["ALL"]
          and sorted(sc["capabilities"]["add"]) == sorted(cs["cap_add"]) and sc.get("readOnlyRootFilesystem") is True,
          f"{name}: the sandbox is not privileged, drops every capability but compose's {len(cs['cap_add'])}, and has a read-only root")
    check(p["securityContext"].get("seccompProfile", {}).get("type") == "RuntimeDefault", f"{name}: RuntimeDefault seccomp")
    check(literal(sandbox).get("GUNICORN_CMD_ARGS") == cs["environment"]["GUNICORN_CMD_ARGS"], f"{name}: the sandbox serves mutual TLS with compose's gunicorn arguments")
    check(all(k in sandbox for k in ("startupProbe", "readinessProbe", "livenessProbe")) and all(k in worker for k in ("startupProbe", "readinessProbe", "livenessProbe")),
          f"{name}: both containers have startup, readiness and liveness probes")
    check(sandbox["resources"]["limits"].get("memory") and sandbox["resources"]["limits"].get("cpu") and sandbox["resources"]["requests"].get("cpu")
          and worker["resources"]["limits"].get("memory"), f"{name}: the sandbox has CPU and memory limits, the worker a memory limit")
    check(p.get("terminationGracePeriodSeconds") == 120 and p.get("shareProcessNamespace") is False, f"{name}: 120 s to finish a judgement, no shared process namespace")
    check(p.get("automountServiceAccountToken") is False, f"{name}: no ServiceAccount token in a pod that runs contestants' code")
    vols = {v["name"]: v for v in p["volumes"]}
    check(vols.get("judger", {}).get("emptyDir", {}).get("medium") == "Memory", f"{name}: /judger is memory-backed (compose: tmpfs)")
    secrets = {v["secret"]["secretName"] for v in p["volumes"] if "secret" in v}
    check(secrets == {"tls-judge-server", worker_tls}, f"{name}: the sandbox gets its own certificate and the worker its own, neither the other's", str(sorted(secrets)))
    mounts = {m["mountPath"] for m in sandbox["volumeMounts"]}
    check("/etc/oj/tls" in mounts and all(m["name"] != next(v["name"] for v in p["volumes"] if v.get("secret", {}).get("secretName") == worker_tls)
          for m in sandbox["volumeMounts"]), f"{name}: the worker's key is not mounted in the sandbox container")

check(find(base, "PodDisruptionBudget", "judge") and find(base, "PodDisruptionBudget", "judge")["spec"]["minAvailable"] == 1, "a PodDisruptionBudget keeps one judge pod")

# the local overlay: the mock sandbox
for name in ("judge", "run-judge"):
    d = find(local, "Deployment", name)
    sb = next((c for c in pod(d).get("initContainers", []) if c["name"] == "sandbox"), None) if d else None
    wk = next((c for c in pod(d)["containers"] if c["name"] == "worker"), None) if d else None
    check(sb and sb["image"] == "mock-judge-server:latest" and sb.get("imagePullPolicy") == "Never" and "DAC_OVERRIDE" in sb["securityContext"]["capabilities"]["add"],
          f"local {name}: the sandbox is the mock (a local image, still able to read the worker's bundles)")
    check(wk and literal(wk).get("JUDGE_SERVER_URL") == "http://localhost:8080", f"local {name}: the worker calls the mock over plain http on localhost")

# network: what the judge pods may reach, and who may reach them
pols = {p["metadata"]["name"]: p["spec"] for p in base if p.get("kind") == "NetworkPolicy"}
def sources(policy, port): return {s["podSelector"]["matchLabels"]["app"] for r in pols.get(policy, {}).get("ingress", []) for s in r["from"]
                                   if "matchLabels" in s.get("podSelector", {}) and any(pp["port"] == port for pp in r["ports"])}
check({"judge", "run-judge"} <= sources("allow-to-kafka", 29092), "Kafka admits the judge pods")
check("judge" in sources("allow-to-minio", 9000) and "run-judge" not in sources("allow-to-minio", 9000), "MinIO admits the judge pod, not the run pod (it keeps no test cases)")
check("judge" in sources("allow-to-submission-service", 8000), "submission-service admits the judge pod's heartbeat relay")
for app in ("judge", "run-judge"):
    eg = pols.get(f"egress-{app}")
    check(eg and eg["podSelector"]["matchLabels"] == {"app": app} and eg["policyTypes"] == ["Egress"] and not any("ipBlock" in t for r in eg["egress"] for t in r.get("to", [])),
          f"{app}: egress is limited to named pods (and DNS), no address range")
    dest = {t["podSelector"]["matchLabels"].get("app") for r in (eg or {}).get("egress", []) for t in r.get("to", []) if "matchLabels" in t.get("podSelector", {})} - {None}   # kube-dns carries k8s-app
    # the judge worker fetches test cases (MinIO) and relays the sandbox's heartbeat (submission-service); the run worker does neither
    want = {"kafka", "jaeger"} | ({"minio", "submission-service"} if app == "judge" else set())
    check(dest == want, f"{app}: it may reach {sorted(want)}", str(sorted(dest)))

# every workload: no ServiceAccount token
tok = [o["metadata"]["name"] for o in base if o.get("kind") in ("Deployment", "StatefulSet", "Job") and pod(o).get("automountServiceAccountToken") is not False]
check(not tok, "no pod of the stack mounts a ServiceAccount token", ", ".join(tok))
sys.exit(1 if failed else 0)
PY

got=$(OJ_DEPLOY_DIR=$tmp bash k3s/scripts/env-to-secrets.sh --dry-run | cut -d' ' -f1 | grep -x minio-worker || true)
[[ -n $got ]] && ok "env-to-secrets.sh makes minio-worker (the key the worker reads test cases with)" || bad "env-to-secrets.sh does not make minio-worker"
exit $fail
