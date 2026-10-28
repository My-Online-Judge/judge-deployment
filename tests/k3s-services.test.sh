#!/usr/bin/env bash
# k3s/base/{services,portal,edge,network} (sub-project 15): the four Java services, the portal, Jaeger and the Traefik edge
# are compose's, not a reinvention. Each service's environment is compared with docker-compose.yml's; the edge's security
# headers and body limits with edge/Caddyfile's; every Service port is reachable only through a NetworkPolicy. The generated
# files do not drift from their generator. Works on a copy of the .example files; prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

for pair in "java:k3s/base/services/java.yaml" "configs:k3s/base/services/configs.yaml"; do
  target=${pair%%:*}; file=${pair#*:}
  if [[ ! -f $file ]]; then bad "$file exists"; continue; fi
  if diff <(python3 k3s/scripts/gen_services.py "$target") "$file" > "$tmp/diff"; then ok "$file is what gen_services.py $target makes"
  else bad "$file differs from the generator (python3 k3s/scripts/gen_services.py $target > $file):"; head -6 "$tmp/diff" | sed 's/^/     /'; fi
done

if ! kubectl kustomize k3s/base > "$tmp/rendered.yaml" 2> "$tmp/err"; then bad "the base renders: $(head -3 "$tmp/err")"; exit 1; fi
docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/rendered.yaml" > "$tmp/rendered.json"
for f in .env*.example; do cp "$f" "$tmp/$f"; done
OJ_DEPLOY_DIR=$tmp bash scripts/local-stack.sh env > /dev/null
docker compose --project-directory "$tmp" -f "$PWD/docker-compose.yml" config --format json > "$tmp/compose.json"
OJ_DEPLOY_DIR=$tmp bash k3s/scripts/env-to-secrets.sh --dry-run > "$tmp/secrets.txt"

python3 - "$tmp" "$PWD/edge/Caddyfile" <<'PY' || fail=1
import json, re, sys
tmp, caddyfile = sys.argv[1:3]
objs = json.load(open(f"{tmp}/rendered.json"))
compose_all = json.load(open(f"{tmp}/compose.json"))
compose = compose_all["services"]
secret_keys = {line.split()[0]: set(line.split()[1].split(",")) for line in open(f"{tmp}/secrets.txt")}
failed = False
def ok(m): print("ok   " + m)
def bad(m):
    global failed
    failed = True
    print("FAIL " + m)
def check(cond, m, detail=""): (ok(m) if cond else bad(m + (": " + detail if detail else "")))
def find(kind, name): return next((o for o in objs if o.get("kind") == kind and o["metadata"]["name"] == name), None)
def pod(o): return o["spec"]["template"]["spec"]

# ---- the four Java services: compose's environment ------------------------------------------------------------------
SERVICES = ["identity-service", "problem-service", "submission-service", "api-gateway"]
for name in SERVICES:
    d = find("Deployment", name)
    if not d: bad(f"a Deployment {name}"); continue
    c = pod(d)["containers"][0]
    literal = {e["name"]: e["value"] for e in c.get("env", []) if "value" in e}
    from_secret_key = {e["name"] for e in c.get("env", []) if "secretKeyRef" in e.get("valueFrom", {})}
    from_env_file = set().union(*[secret_keys.get(r["secretRef"]["name"], set()) for r in c.get("envFrom", [])]) if c.get("envFrom") else set()
    comp = {k: str(v) for k, v in compose[name]["environment"].items()}
    have = set(literal) | from_secret_key | from_env_file
    missing, extra = sorted(set(comp) - have), sorted(have - set(comp))
    check(not missing and not extra, f"{name}: the same {len(comp)} environment variables as compose", f"missing {missing}, not in compose {extra}")
    differ = sorted(k for k, v in literal.items() if k in comp and k != "JAVA_TOOL_OPTIONS" and comp[k] != v)
    check(not differ, f"{name}: every literal value is compose's", ", ".join(f"{k}: {literal[k]!r} vs {comp[k]!r}" for k in differ))
    jto = literal.get("JAVA_TOOL_OPTIONS", "")
    check("-XX:MaxRAMPercentage=50.0" in jto and "-XX:+UseSerialGC" in jto and "-javaagent:/otel/opentelemetry-javaagent.jar" in jto
          and "-Djava.security.properties=/opt/oj/jvm-dns.security" in jto and "-Dnetworkaddress.cache.ttl=1" in jto,
          f"{name}: JAVA_TOOL_OPTIONS has the OpenTelemetry agent, DNS caching, 50% heap and the serial collector", jto)
    for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
        check(probe in c, f"{name}: a {probe}")
    check(c["resources"]["limits"].get("memory") and c["resources"]["requests"].get("memory"), f"{name}: memory request and limit")
    check(c["securityContext"].get("readOnlyRootFilesystem") is True and any(v["name"] == "tmp" for v in pod(d)["volumes"]),
          f"{name}: a read-only root filesystem with /tmp as an emptyDir")
check((find("Deployment", "submission-service") or {}).get("spec", {}).get("strategy", {}).get("type") == "Recreate", "submission-service is replaced, not rolled (its run registry is in memory)")
grpc = find("Service", "problem-service")
check(grpc and {p["port"] for p in grpc["spec"]["ports"]} == {8000, 8081, 9090}, "Service problem-service exposes 8000, 8081 and the gRPC 9090")
for name in ("identity-service", "submission-service", "api-gateway"):
    s = find("Service", name)
    check(s and {p["port"] for p in s["spec"]["ports"]} == {8000, 8081}, f"Service {name} exposes 8000 and 8081")

dns = find("ConfigMap", "jvm-dns-security")
check(dns and dns["data"]["jvm-dns.security"].strip() == compose_all["configs"]["jvm-dns-security"]["content"].strip(), "the JVM's DNS caching properties are compose's")

# ---- portal and Jaeger -----------------------------------------------------------------------------------------------
for name, ports in (("judge-portal", {443}), ("jaeger", {4317, 4318})):
    d, s = find("Deployment", name), find("Service", name)
    check(d and s and {p["port"] for p in s["spec"]["ports"]} == ports, f"{name}: a Deployment and a Service on {sorted(ports)}")

# ---- hardening of every pod of this layer ----------------------------------------------------------------------------
layer = [find("Deployment", n) for n in SERVICES + ["judge-portal", "jaeger"]]
weak = []
for d in layer:
    if not d: continue
    p, n = pod(d), d["metadata"]["name"]
    sc = p.get("securityContext", {})
    if sc.get("seccompProfile", {}).get("type") != "RuntimeDefault": weak.append(f"{n}: seccomp")
    if p.get("enableServiceLinks") is not False: weak.append(f"{n}: service links")
    for c in p["containers"]:
        csc = c.get("securityContext", {})
        if csc.get("allowPrivilegeEscalation") is not False or csc.get("capabilities", {}).get("drop") != ["ALL"]: weak.append(f"{n}: capabilities")
        if not (csc.get("runAsNonRoot") or sc.get("runAsNonRoot")): weak.append(f"{n}: may run as root")
        if not c["resources"].get("limits", {}).get("memory"): weak.append(f"{n}: no memory limit")
check(not weak, "services, portal and Jaeger: RuntimeDefault seccomp, no escalation, capabilities dropped, non-root, memory-limited, no service links", "; ".join(weak[:5]))

# ---- the edge: Caddy's headers and limits, in Traefik's terms --------------------------------------------------------
caddy = open(caddyfile).read()
csp = re.search(r'Content-Security-Policy "([^"]+)"', caddy).group(1)
mw = find("Middleware", "security-headers")
h = (mw or {}).get("spec", {}).get("headers", {})
check(mw and h.get("contentSecurityPolicy") == csp, "the edge's Content-Security-Policy is Caddy's, character for character")
hdr = h.get("customResponseHeaders", {})
check(hdr.get("X-Content-Type-Options") == "nosniff" and h.get("referrerPolicy") == "strict-origin-when-cross-origin"
      and (h.get("frameDeny") is True or hdr.get("X-Frame-Options") == "DENY"), "nosniff, the referrer policy and no framing, as Caddy sets them")
units = {"MB": 1000_000, "MiB": 1024 * 1024}
def size(text):
    m = re.fullmatch(r"(\d+)(MB|MiB)", text); return int(m.group(1)) * units[m.group(2)]
upload = size(re.search(r"request_body @problemUploads \{\s*max_size (\S+)", caddy).group(1))
other = size(re.search(r"request_body @otherBodies \{\s*max_size (\S+)", caddy).group(1))
limits = {m["metadata"]["name"]: m["spec"]["buffering"]["maxRequestBodyBytes"] for m in objs if m.get("kind") == "Middleware" and "buffering" in m["spec"]}
check(limits.get("body-limit-problems") == upload and limits.get("body-limit-api") == other,
      f"body limits: {upload} bytes for problem uploads and {other} for the rest of the API, as in Caddy", str(limits))
routes = [r for o in objs if o.get("kind") == "IngressRoute" for r in o["spec"]["routes"]]
def to(service): return [r for r in routes if r["services"][0]["name"] == service]
check(any("PathPrefix(`/api`)" in r["match"] for r in to("api-gateway")) and any("/api/v1/problems" in r["match"] for r in to("api-gateway"))
      and any(r["match"] == "PathPrefix(`/`)" for r in to("judge-portal")), "routes: /api and /api/v1/problems to the gateway, everything else to the portal")
backends = [r for r in routes if r["services"][0].get("kind") != "TraefikService"]
check(backends and all(r["services"][0].get("scheme") == "https" and r["services"][0].get("serversTransport") for r in backends), "every route to a service reaches it over HTTPS with a ServersTransport")
redirect = [r for r in routes if r["services"][0].get("kind") == "TraefikService"]
check(len(redirect) == 1 and redirect[0]["middlewares"][0]["name"] == "redirect-https", "port 80 only redirects to https")
transports = {t["metadata"]["name"]: t["spec"] for t in objs if t.get("kind") == "ServersTransport"}
check(all("tls-edge" in t.get("certificatesSecrets", []) for t in transports.values()) and transports, "Traefik presents the edge identity's certificate (CN=edge) to the gateway and the portal")
check({t.get("serverName") for t in transports.values()} == {"api-gateway", "judge-portal"}, "each backend is verified under its own certificate name")

# ---- network policies: every port is reachable only through an allow rule --------------------------------------------
pols = [o for o in objs if o.get("kind") == "NetworkPolicy"]
check(any(p["spec"]["podSelector"] == {} and p["spec"].get("policyTypes") == ["Ingress"] and not p["spec"].get("ingress") for p in pols), "a default-deny ingress policy covers the namespace")
EXEMPT = {8081}   # the actuators: Prometheus's allow rule comes with the observability task
uncovered = []
for s in (o for o in objs if o.get("kind") == "Service"):
    sel = s["spec"]["selector"]
    for port in {p["port"] for p in s["spec"]["ports"]} - EXEMPT:
        allowed = any(all(sel.get(k) == v for k, v in p["spec"]["podSelector"].get("matchLabels", {}).items()) and p["spec"]["podSelector"].get("matchLabels")
                      and any(port == pp.get("port") for rule in p["spec"].get("ingress", []) for pp in rule.get("ports", []))
                      for p in pols)
        if not allowed: uncovered.append(f'{s["metadata"]["name"]}:{port}')
check(not uncovered, "every Service port (but the actuators') has a NetworkPolicy allowing it", ", ".join(uncovered))
sys.exit(1 if failed else 0)
PY
exit $fail
