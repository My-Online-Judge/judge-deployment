#!/usr/bin/env bash
# KEDA on K3s (sub-project 15): the judge pods scale with the lag of their Kafka consumer group, never to zero and never past a
# ceiling; KEDA reads the lag over mutual TLS as its own Kafka identity (CN=keda), which kafka/acls.sh lets describe those two
# groups and topics and nothing else. Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

kubectl kustomize k3s/base > "$tmp/base.yaml" 2> "$tmp/err" || { bad "the base renders: $(head -3 "$tmp/err")"; exit 1; }
kubectl kustomize k3s/platform > "$tmp/platform.yaml" 2> "$tmp/err" || { bad "the platform renders: $(head -3 "$tmp/err")"; exit 1; }
docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/base.yaml" > "$tmp/base.json"
docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/platform.yaml" > "$tmp/platform.json"

python3 - "$tmp" <<'PY' || fail=1
import json, re, sys
tmp = sys.argv[1]
base, platform = json.load(open(f"{tmp}/base.json")), json.load(open(f"{tmp}/platform.json"))
failed = False
def ok(m): print("ok   " + m)
def bad(m):
    global failed
    failed = True
    print("FAIL " + m)
def check(cond, m, detail=""): (ok(m) if cond else bad(m + (": " + detail if detail else "")))
def find(objs, kind, name): return next((o for o in objs if o.get("kind") == kind and o["metadata"]["name"] == name), None)

keda = find(platform, "HelmChart", "keda")
check(keda and re.fullmatch(r"v?\d+\.\d+\.\d+", keda["spec"]["version"]) and keda["spec"]["targetNamespace"] == "keda", "the platform installs KEDA at an exact chart version into its own namespace")
alias = find(platform, "Service", "kafka")
check(alias and alias["metadata"].get("namespace") == "keda" and alias["spec"].get("type") == "ExternalName" and alias["spec"].get("externalName") == "kafka.oj.svc.cluster.local",
      "KEDA's namespace resolves `kafka` (the broker's advertised name) to the broker's Service in oj")
check(find(platform, "Namespace", "keda"), "the namespace keda is declared, so the alias can be applied before the chart makes it")
check(keda and "limits" in keda["spec"].get("valuesContent", "") and "memory" in keda["spec"].get("valuesContent", ""), "KEDA's pods have memory limits")

# (scaled object, deployment, group, topic, max, lag threshold)
WANT = (("judge", "judge-workers", "submission.requested", 4, "5"), ("run-judge", "run-workers", "run.requested", 2, "3"))
for name, group, topic, ceiling, lag in WANT:
    so = find(base, "ScaledObject", name)
    if not so: bad(f"a ScaledObject {name}"); continue
    s = so["spec"]
    check(s["scaleTargetRef"]["name"] == name, f"{name}: it scales the Deployment {name}")
    check(s["minReplicaCount"] >= 1, f"{name}: never to zero (the heartbeat relay and a warm sandbox need a pod)")
    check(s["maxReplicaCount"] == ceiling, f"{name}: at most {ceiling} pods")
    check(s["cooldownPeriod"] == 300 and s["advanced"]["horizontalPodAutoscalerConfig"]["behavior"]["scaleDown"]["stabilizationWindowSeconds"] == 300,
          f"{name}: a pod stays five minutes after the load is gone (cooldownPeriod only covers scale-to-zero; the HPA window covers the steps between)")
    t = s["triggers"][0]
    m = t["metadata"]
    check(t["type"] == "kafka" and m["consumerGroup"] == group and m["topic"] == topic and m["lagThreshold"] == lag,
          f"{name}: Kafka lag of {group} on {topic}, one more pod per {lag} waiting", json.dumps(m))
    check(m["bootstrapServers"] == "kafka.oj.svc.cluster.local:29092" and m.get("tls") == "enable",
          f"{name}: KEDA reaches Kafka by its in-cluster name over TLS (KEDA runs in another namespace)")
    check(m.get("allowIdleConsumers") in (None, "false", False) and m.get("offsetResetPolicy") == "earliest", f"{name}: no more pods than partitions' worth of lag, new groups read from the start")
    check(t["authenticationRef"]["name"] == "keda-kafka", f"{name}: the trigger authenticates with TriggerAuthentication keda-kafka")
    d = find(base, "Deployment", name)
    check(d and "replicas" not in d["spec"], f"{name}: the Deployment sets no replicas (KEDA's HorizontalPodAutoscaler owns the count; an apply must not reset it)")

ta = find(base, "TriggerAuthentication", "keda-kafka")
refs = {r["parameter"]: (r["name"], r["key"]) for r in (ta or {}).get("spec", {}).get("secretTargetRef", [])}
check(refs == {"ca": ("tls-keda", "ca.crt"), "cert": ("tls-keda", "tls.crt"), "key": ("tls-keda", "tls.key")}, "KEDA's client certificate is the identity keda (tls-keda)")

pols = {p["metadata"]["name"]: p["spec"] for p in base if p.get("kind") == "NetworkPolicy"}
admits = any(s.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name") == "keda"
             for r in pols.get("allow-to-kafka", {}).get("ingress", []) for s in r["from"] if any(pp["port"] == 29092 for pp in r["ports"]))
check(admits, "Kafka admits KEDA's namespace on 29092")
sys.exit(1 if failed else 0)
PY
exit $fail
