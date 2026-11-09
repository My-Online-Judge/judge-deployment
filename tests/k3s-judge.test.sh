#!/usr/bin/env bash
# k3s/base/judge (sub-project 15): the Judge Pod pairs a sandbox with a worker, one to one. The worker's environment and the
# sandbox's hardening are compared with docker-compose.yml's; the sandbox is a native sidecar (it starts first and stops last,
# so a judgement in flight finishes); the pod has no ServiceAccount token and may reach only what the worker needs; the local
# overlay runs the same sandbox image as the mock. Works on a copy of the .example files; prints descriptions.
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
import json, re, sys
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
def seconds(d):   # compose prints a duration as 6m0s
    m = re.fullmatch(r"(?:(\d+)m)?(?:(\d+)s)?", d)
    return int(m.group(1) or 0) * 60 + int(m.group(2) or 0) if m else None
def pod(o): return o["spec"]["template"]["spec"]
def literal(c): return {e["name"]: e["value"] for e in c.get("env", []) if "value" in e}
def names(c): return {e["name"] for e in c.get("env", [])}

PAIRS = (("judge", "judge-worker", "tls-judge-worker"), ("run-judge", "run-worker", "tls-run-worker"))
EXTRA = {"judge": {"POD_NAME", "CONSUMER_GROUP", "MAX_POLL_INTERVAL_MS", "TEST_CASE_CACHE_TTL_SECONDS"}, "run-judge": {"POD_NAME"}}
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
    check(worker["image"] == compose["judge-worker" if name == "judge" else "run-worker"]["image"], f"{name}: the worker image compose runs (same registry, same tag)", worker["image"])
    lit = literal(worker)
    differ = sorted(k for k, v in lit.items() if k in comp_env and k != "JUDGE_SERVER_URL" and comp_env[k] != v)
    check(not differ, f"{name}: every literal value is compose's", ", ".join(f"{k}: {lit[k]!r} vs {comp_env[k]!r}" for k in differ))
    check(lit.get("JUDGE_SERVER_URL") == "localhost:8080", f"{name}: the worker calls its own sandbox (gRPC, mutual TLS from OJ_TLS_DIR) on localhost:8080")
    pn = next((e for e in worker["env"] if e["name"] == "POD_NAME"), {})
    check(pn.get("valueFrom", {}).get("fieldRef", {}).get("fieldPath") == "metadata.name", f"{name}: POD_NAME comes from the Downward API")
    if name == "judge":
        check(lit.get("CONSUMER_GROUP") == "judge-workers" and lit.get("MAX_POLL_INTERVAL_MS") == "900000", "judge: consumer group judge-workers, 15 minute poll interval (two sandboxes at the 300 s deadline cap plus the MinIO budget)")
        check(12003 in p["securityContext"].get("supplementalGroups", []), "judge: the worker is in group 12003 (the checker's group), as compose's group_add")
    # the sandbox: compose's image, command environment and hardening
    cs = compose["judge-server"]
    sc = sandbox["securityContext"]
    check(sandbox["image"] == cs["image"] == "docker.io/thanhtuanle/judge-server:main", f"{name}: the sandbox image is compose's (the Go judge-server, same registry and tag)", sandbox["image"])
    check(sc.get("privileged") in (None, False) and sc.get("allowPrivilegeEscalation") is False and sc["capabilities"]["drop"] == ["ALL"]
          and sorted(sc["capabilities"]["add"]) == sorted(cs["cap_add"]) and sc.get("readOnlyRootFilesystem") is True,
          f"{name}: the sandbox is not privileged, drops every capability but compose's {len(cs['cap_add'])}, and has a read-only root")
    check(p["securityContext"].get("seccompProfile", {}).get("type") == "RuntimeDefault", f"{name}: RuntimeDefault seccomp")
    check(any(m["mountPath"] == "/opt/oj/java.policy" and m.get("readOnly") for m in sandbox["volumeMounts"]), f"{name}: the sandbox mounts the Java security policy")
    ce = {k: str(v) for k, v in cs["environment"].items() if k != "TOKEN"}
    check(literal(sandbox) == {**ce, "HEALTHCHECK_SERVER_NAME": "judge-server"} and "GUNICORN_CMD_ARGS" not in names(sandbox) and "SERVICE_URL" not in names(sandbox),
          f"{name}: the sandbox has compose's literal environment (TLS_DIR, JUDGE_ALLOWED_CLIENTS, LOG_FORMAT) plus HEALTHCHECK_SERVER_NAME, no gunicorn or SERVICE_URL", str(literal(sandbox)))
    tok = next((e for e in sandbox["env"] if e["name"] == "TOKEN"), {}).get("valueFrom", {}).get("secretKeyRef", {})
    check(tok == {"name": "judge-token", "key": "JUDGE_SERVER_TOKEN"}, f"{name}: the sandbox's TOKEN is the judge-token secret, as the worker's JUDGE_SERVER_TOKEN")
    check(all(k in sandbox for k in ("startupProbe", "readinessProbe", "livenessProbe")) and all(k in worker for k in ("startupProbe", "readinessProbe", "livenessProbe")),
          f"{name}: both containers have startup, readiness and liveness probes")
    hc = cs["healthcheck"]["test"][1:]
    check(all(sandbox[k].get("exec", {}).get("command") == hc for k in ("startupProbe", "readinessProbe", "livenessProbe")) and hc == ["/usr/local/bin/judge-server", "healthcheck"]
          and not sandbox["readinessProbe"].get("initialDelaySeconds") and not sandbox["livenessProbe"].get("initialDelaySeconds")
          and sandbox["startupProbe"]["periodSeconds"] * sandbox["startupProbe"]["failureThreshold"] >= 60,
          f"{name}: the sandbox's three probes run compose's healthcheck command; the startup probe's window covers compose's 60 s start period (no fixed delay on readiness or liveness)")
    # The healthcheck verifies the server certificate for HEALTHCHECK_SERVER_NAME (the name in tls-judge-server), so the pod keeps its own hostname:
    # forcing it to judge-server would make every judge pod report the same name and share one registry row.
    check(literal(sandbox).get("HEALTHCHECK_SERVER_NAME") == "judge-server" and "hostname" not in p,
          f"{name}: the sandbox's healthcheck verifies the certificate for HEALTHCHECK_SERVER_NAME=judge-server and the pod keeps its own hostname (one registry row per pod)")
    lim, req = sandbox["resources"]["limits"], sandbox["resources"]["requests"]
    check(lim.get("memory") == "1536Mi" and 1536 * 1024 * 1024 == int(cs["mem_limit"]) and lim.get("cpu") == "2" and float(cs["cpus"]) == 2 and req.get("cpu") == "1" and req.get("memory") == "768Mi"
          and worker["resources"]["limits"].get("memory"), f"{name}: the sandbox has compose's 1.5 GiB and 2 CPUs as limits (requests 1 CPU, 768Mi), the worker a memory limit")
    grace = seconds(compose["judge-worker" if name == "judge" else "run-worker"]["stop_grace_period"])
    check(p.get("terminationGracePeriodSeconds") == 360 and grace == 360 and p.get("shareProcessNamespace") is False,
          f"{name}: 360 s to finish a judgement (compose's 6m stop_grace_period), no shared process namespace", f"grace {grace}")
    check(p.get("automountServiceAccountToken") is False, f"{name}: no ServiceAccount token in a pod that runs contestants' code")
    vols = {v["name"]: v for v in p["volumes"]}
    mounts_by_path = {m["mountPath"]: m["name"] for m in sandbox["volumeMounts"]}
    check(vols.get(mounts_by_path.get("/work"), {}).get("emptyDir") == {"medium": "Memory", "sizeLimit": "512Mi"}
          and vols.get(mounts_by_path.get("/tmp"), {}).get("emptyDir") == {"medium": "Memory", "sizeLimit": "64Mi"},
          f"{name}: /work (512Mi) and /tmp (64Mi) are memory-backed (compose: tmpfs)")
    # compose's /work tmpfs is mode=755: only root may write under it. A pod's emptyDir is 0777 (fsGroup adds setgid), so an init step must
    # close it before the sandbox starts, or the run uids (12100-12107) could write directly under /work.
    order = [c["name"] for c in p.get("initContainers", [])]
    perm = sidecars.get("sandbox-work-perms", {})
    psc = perm.get("securityContext", {})
    check(perm and perm.get("restartPolicy") != "Always" and "sandbox" in order and order.index("sandbox-work-perms") < order.index("sandbox")
          and perm.get("image") == sandbox["image"] and perm.get("command") == ["/bin/sh", "-c", "chmod 0755 /work"]
          and any(m["mountPath"] == "/work" and m["name"] == mounts_by_path.get("/work") for m in perm.get("volumeMounts", []))
          and psc.get("runAsUser") == 0 and psc.get("allowPrivilegeEscalation") is False and psc.get("capabilities") == {"drop": ["ALL"]},
          f"{name}: an init step (before the sandbox starts, as root with no capabilities) makes /work root-owned 0755, as compose's tmpfs mode=755: the run users cannot write under it")
    check("/judger" not in mounts_by_path and "/log" not in mounts_by_path and "/dev/shm" not in mounts_by_path and not {"judger", "sandbox-log", "dev-shm"} & set(vols),
          f"{name}: no /judger, /log or /dev/shm volume (the Go server has none; compose dropped shm_size and the log volumes)")
    secrets = {v["secret"]["secretName"] for v in p["volumes"] if "secret" in v}
    check(secrets == {"tls-judge-server", worker_tls}, f"{name}: the sandbox gets its own certificate and the worker its own, neither the other's", str(sorted(secrets)))
    mounts = {m["mountPath"] for m in sandbox["volumeMounts"]}
    check("/etc/oj/tls" in mounts and all(m["name"] != next(v["name"] for v in p["volumes"] if v.get("secret", {}).get("secretName") == worker_tls)
          for m in sandbox["volumeMounts"]), f"{name}: the worker's key is not mounted in the sandbox container")

# rollout and drain on one node: a PodDisruptionBudget of 1 on one replica would stop `kubectl drain` for good, and a surge pod needs 0.875Gi
# free (the node's memory is the ceiling, see k3s/README.md), so a rollout replaces the pod in place; Kafka holds the records meanwhile
check(find(base, "PodDisruptionBudget", "judge") is None, "no PodDisruptionBudget: it can only block a drain on a single node (the 360 s grace period still lets a judgement finish)")
for name in ("judge", "run-judge"):
    d = find(base, "Deployment", name)
    check(d and d["spec"]["strategy"] == {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}}, f"{name}: a rollout replaces the pod (maxSurge 0, maxUnavailable 1) instead of stalling for memory to surge")
jd = find(base, "Deployment", "judge")
cases = next((v for v in pod(jd)["volumes"] if v["name"] == "cases"), {}) if jd else {}
check(cases.get("emptyDir", {}).get("sizeLimit") == "8Gi", "judge: the test-case cache may grow to 8Gi before the kubelet evicts the pod (2Gi could evict it mid-judgement)")
wk = next((c for c in pod(jd)["containers"] if c["name"] == "worker"), {}) if jd else {}
check({e["name"]: e.get("value") for e in wk.get("env", [])}.get("TEST_CASE_CACHE_TTL_SECONDS") == "21600", "judge: cached bundles unused for 6 hours are swept (the worker's default is 24 h; the cache is capped by size, so it ages out sooner)")

# the local overlay: the same sandbox image running `mock`, everything else (TLS, token, probes, capabilities, the worker's address) the base's
for name in ("judge", "run-judge"):
    d, b = find(local, "Deployment", name), find(base, "Deployment", name)
    sb = next((c for c in pod(d).get("initContainers", []) if c["name"] == "sandbox"), None) if d else None
    bsb = next((c for c in pod(b).get("initContainers", []) if c["name"] == "sandbox"), None) if b else None
    wk = next((c for c in pod(d)["containers"] if c["name"] == "worker"), None) if d else None
    bwk = next((c for c in pod(b)["containers"] if c["name"] == "worker"), None) if b else None
    check(sb and bsb and sb["image"] == bsb["image"] and sb.get("args") == ["mock"] and "DAC_OVERRIDE" in sb["securityContext"]["capabilities"]["add"],
          f"local {name}: the sandbox is the base's image running `mock` (still able to read the worker's bundles)")
    check(sb and bsb and {e["name"] for e in sb["env"]} - {e["name"] for e in bsb["env"]} == {"MOCK_SLOW_SECONDS"} and all(sb[k] == bsb[k] for k in ("startupProbe", "readinessProbe", "livenessProbe", "volumeMounts")),
          f"local {name}: the mock adds MOCK_SLOW_SECONDS to the base's environment and keeps its probes and mounts")
    check(wk and bwk and wk["env"] == bwk["env"] and literal(wk).get("JUDGE_SERVER_URL") == "localhost:8080", f"local {name}: the worker is untouched: it calls the mock at localhost:8080 over the same mutual TLS")

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

# every workload: no ServiceAccount token, but the two that read the Kubernetes API (tests/k3s-observability.test.sh checks their roles)
API_READERS = {"prometheus", "kube-state-metrics"}
tok = [o["metadata"]["name"] for o in base if o.get("kind") in ("Deployment", "StatefulSet", "Job") and o["metadata"]["name"] not in API_READERS
       and pod(o).get("automountServiceAccountToken") is not False]
check(not tok, "no pod of the stack mounts a ServiceAccount token (but Prometheus's and kube-state-metrics')", ", ".join(tok))
sys.exit(1 if failed else 0)
PY

got=$(OJ_DEPLOY_DIR=$tmp bash k3s/scripts/env-to-secrets.sh --dry-run | cut -d' ' -f1 | grep -x minio-worker || true)
[[ -n $got ]] && ok "env-to-secrets.sh makes minio-worker (the key the worker reads test cases with)" || bad "env-to-secrets.sh does not make minio-worker"
exit $fail
