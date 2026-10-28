#!/usr/bin/env bash
# The server overlays (sub-project 15): `vps` is the whole stack with the public name and a Let's Encrypt certificate for the edge;
# `vps-stage1` is the same without the judge pods and KEDA, for the first steps of the cutover (the services run on K3s while compose
# still judges). The public host and the ACME email are two values in overlays/vps/host.env, copied into the gateway's CORS origin,
# the certificate and the issuer. Traefik keeps the client's address (the gateway bans by it). Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
bad() { echo "FAIL $1"; fail=1; }
for o in vps vps-stage1; do
  if [[ -f k3s/overlays/$o/kustomization.yaml ]] && kubectl kustomize k3s/overlays/$o > "$tmp/$o.yaml" 2> "$tmp/err"; then
    docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/$o.yaml" > "$tmp/$o.json"
  else bad "overlay $o renders: $(head -2 "$tmp/err" 2> /dev/null)"; echo '[]' > "$tmp/$o.json"; fi
done
kubectl kustomize k3s/platform > "$tmp/platform.yaml" 2> "$tmp/err" || bad "platform renders: $(head -2 "$tmp/err")"
docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/platform.yaml" > "$tmp/platform.json"

python3 - "$tmp" <<'PY' || fail=1
import json, sys
tmp = sys.argv[1]
vps, stage1, platform = (json.load(open(f"{tmp}/{n}.json")) for n in ("vps", "vps-stage1", "platform"))
failed = False
def ok(m): print("ok   " + m)
def bad(m):
    global failed
    failed = True
    print("FAIL " + m)
def check(cond, m, detail=""): (ok(m) if cond else bad(m + (": " + detail if detail else "")))
def find(objs, kind, name): return next((o for o in objs if o.get("kind") == kind and o["metadata"]["name"] == name), None)
def ids(objs): return {(o["kind"], o["metadata"]["name"]) for o in objs}

host = dict(l.split("=", 1) for l in open("k3s/overlays/vps/host.env").read().split("\n") if "=" in l and not l.startswith("#")) if __import__("os").path.exists("k3s/overlays/vps/host.env") else {}
check(host.get("OJ_PUBLIC_HOST", "").endswith(".invalid") or "." in host.get("OJ_PUBLIC_HOST", ""), "overlays/vps/host.env names the public host", str(host))
check("@" in host.get("ACME_EMAIL", ""), "overlays/vps/host.env names the ACME email")

# stage 1 = vps minus the judge pods and KEDA, and nothing else
judge_side = {("Deployment", "judge"), ("Deployment", "run-judge"), ("ScaledObject", "judge"), ("ScaledObject", "run-judge"), ("PodDisruptionBudget", "judge")}
check(judge_side <= ids(vps), "vps has the judge pods, their scalers and the budget", str(judge_side - ids(vps)))
check(not (judge_side & ids(stage1)), "vps-stage1 has none of them", str(judge_side & ids(stage1)))
check(ids(vps) - ids(stage1) == judge_side & ids(vps), "vps-stage1 is vps and nothing else removed", str((ids(vps) - ids(stage1)) - judge_side))

# the public name, in the gateway, the certificate and the issuer
for label, objs in (("vps", vps), ("vps-stage1", stage1)):
    gw = find(objs, "Deployment", "api-gateway")
    env = {e["name"]: e.get("value") for e in gw["spec"]["template"]["spec"]["containers"][0]["env"]} if gw else {}
    check(env.get("OJ_PUBLIC_HOST") == host.get("OJ_PUBLIC_HOST") and env.get("OJ_PUBLIC_HOST") != "localhost", f"{label}: the gateway's OJ_PUBLIC_HOST is the public host, not localhost", str(env.get("OJ_PUBLIC_HOST")))
    cert = find(objs, "Certificate", "edge-tls")
    check(cert and cert["spec"]["secretName"] == "edge-tls" and cert["spec"]["dnsNames"] == [host.get("OJ_PUBLIC_HOST")]
          and cert["spec"]["issuerRef"] == {"name": "letsencrypt", "kind": "ClusterIssuer", "group": "cert-manager.io"} and "ipAddresses" not in cert["spec"],
          f"{label}: edge-tls is a Let's Encrypt certificate for the public host", json.dumps(cert and cert["spec"])[:200])
    iss = find(objs, "ClusterIssuer", "letsencrypt")
    acme = (iss or {}).get("spec", {}).get("acme", {})
    check(acme.get("server") == "https://acme-v02.api.letsencrypt.org/directory" and acme.get("email") == host.get("ACME_EMAIL")
          and acme.get("privateKeySecretRef", {}).get("name") and acme.get("solvers", [{}])[0].get("http01", {}).get("ingress", {}).get("ingressClassName") == "traefik",
          f"{label}: the issuer letsencrypt (production ACME, HTTP-01 through Traefik) uses the ACME email", json.dumps(acme)[:200])

# Traefik keeps the client's address: the gateway bans and counts by it, and K3s's service load balancer would otherwise hide it
cfg = find(platform, "HelmChartConfig", "traefik")
values = (cfg or {}).get("spec", {}).get("valuesContent", "")
check(cfg and cfg["metadata"].get("namespace") == "kube-system" and "externalTrafficPolicy: Local" in values,
      "the platform sets Traefik's Service to externalTrafficPolicy: Local (the gateway sees the real client address)", values[:120])
sys.exit(1 if failed else 0)
PY
exit $fail
