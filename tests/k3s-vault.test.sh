#!/usr/bin/env bash
# Vault on K3s (docs/superpowers/specs/2026-11-12-vault-secrets-design.md): the server overlays (vps, vps-stage1) keep the stack's Secrets
# in HashiCorp Vault and let the Vault Secrets Operator write them under the names the pods already read; the base and the local
# overlay (k3d, CI) keep env-to-secrets.sh. Checks: the generated VaultStaticSecrets match the one Secret table and the workloads that read
# each Secret, Vault's pod and certificate are hardened like the data layer's, only the operator can reach Vault, and k3s/scripts/vault.sh
# never puts a token or a value on a command line, stops at the first failure and gives the operator a read-only policy. Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

if diff <(python3 k3s/scripts/gen_vault.py) k3s/components/vault/secrets.yaml > "$tmp/diff" 2>&1; then ok "k3s/components/vault/secrets.yaml is what gen_vault.py makes"
else bad "k3s/components/vault/secrets.yaml differs from the generator (python3 k3s/scripts/gen_vault.py > k3s/components/vault/secrets.yaml):"; head -6 "$tmp/diff" | sed 's/^/     /'; fi

for o in base overlays/local overlays/vps overlays/vps-stage1 platform; do
  n=${o//\//-}
  if kubectl kustomize k3s/$o > "$tmp/$n.yaml" 2> "$tmp/err"; then docker --context "$ctx" run --rm -i "$yq" ea '[.]' -o=json < "$tmp/$n.yaml" > "$tmp/$n.json"
  else bad "$o renders: $(head -3 "$tmp/err")"; echo '[]' > "$tmp/$n.json"; fi
done
for f in .env*.example; do cp "$f" "$tmp/$f"; done
OJ_DEPLOY_DIR=$tmp bash scripts/local-stack.sh env > /dev/null
OJ_DEPLOY_DIR=$tmp bash k3s/scripts/env-to-secrets.sh --dry-run > "$tmp/secrets.txt"

python3 - "$tmp" <<'PY' || fail=1
import json, re, sys
tmp = sys.argv[1]
load = lambda n: json.load(open(f"{tmp}/{n}.json"))
vps, stage1, local, base, platform = (load(n) for n in ("overlays-vps", "overlays-vps-stage1", "overlays-local", "base", "platform"))
secret_keys = {l.split()[0]: set(l.split()[1].split(",")) for l in open(f"{tmp}/secrets.txt")}
failed = False
def ok(m): print("ok   " + m)
def bad(m):
    global failed
    failed = True
    print("FAIL " + m)
def check(cond, m, detail=""): (ok(m) if cond else bad(m + (": " + detail if detail else "")))
def find(objs, kind, name): return next((o for o in objs if o.get("kind") == kind and o["metadata"]["name"] == name), None)
def pod_refs(pod):
    refs = set()
    for c in pod.get("containers", []) + pod.get("initContainers", []):
        refs |= {e["secretRef"]["name"] for e in c.get("envFrom", []) if "secretRef" in e}
        refs |= {e["valueFrom"]["secretKeyRef"]["name"] for e in c.get("env", []) if "secretKeyRef" in e.get("valueFrom", {})}
    for v in pod.get("volumes", []):
        if "secret" in v: refs.add(v["secret"]["secretName"])
    return refs

VAULT_KINDS = {"VaultConnection", "VaultAuth", "VaultStaticSecret"}
for label, objs in (("base", base), ("the local overlay", local)):
    found = [o["metadata"]["name"] for o in objs if o.get("kind") in VAULT_KINDS or o["metadata"]["name"] in ("vault", "vault-config")]
    check(not found, f"{label} has no Vault objects (it keeps env-to-secrets.sh)", str(found))

for label, objs in (("vps", vps), ("vps-stage1", stage1)):
    sts = find(objs, "StatefulSet", "vault")
    if not sts: bad(f"{label}: a StatefulSet vault"); continue
    pod, c = sts["spec"]["template"]["spec"], sts["spec"]["template"]["spec"]["containers"][0]
    csc, psc = c.get("securityContext", {}), pod.get("securityContext", {})
    check(sts["spec"]["replicas"] == 1 and sts["spec"]["serviceName"] == "vault-internal", f"{label}: one Vault node behind the headless Service vault-internal")
    check(re.fullmatch(r"hashicorp/vault:\d+\.\d+\.\d+", c["image"]) is not None, f"{label}: the image is an exact release, never a floating tag", c["image"])
    check(c.get("resources", {}).get("limits", {}).get("memory"), f"{label}: Vault has a memory limit")
    check(psc.get("seccompProfile", {}).get("type") == "RuntimeDefault" and csc.get("allowPrivilegeEscalation") is False
          and csc.get("capabilities", {}).get("drop") == ["ALL"] and "add" not in csc.get("capabilities", {}) and (csc.get("runAsNonRoot") or psc.get("runAsNonRoot")),
          f"{label}: RuntimeDefault seccomp, no privilege escalation, every capability dropped (none added back, IPC_LOCK included: Pod Security baseline), non-root")
    check(pod.get("enableServiceLinks") is False and pod.get("serviceAccountName") == "vault", f"{label}: no service links, its own ServiceAccount")
    check(sts["spec"].get("volumeClaimTemplates"), f"{label}: Vault's data (the Raft store) is on a claim")
    check("tls-vault" in pod_refs(pod), f"{label}: Vault serves with the certificate in tls-vault")
    probe = c.get("readinessProbe", {}).get("httpGet", {})
    check(probe.get("scheme") == "HTTPS" and probe.get("path", "").startswith("/v1/sys/health"), f"{label}: Vault is Ready only when it is unsealed (a sealed Vault shows as 0/1 in kubectl get pods)", json.dumps(probe))

    cfg = (find(objs, "ConfigMap", "vault-config") or {}).get("data", {}).get("vault.hcl", "")
    check('storage "raft"' in cfg and "disable_mlock = true" in cfg and "tls_cert_file" in cfg and "tls_key_file" in cfg and "tls_disable" not in cfg,
          f"{label}: Raft storage, TLS on the listener (never tls_disable), mlock off (no IPC_LOCK)")

    cert = find(objs, "Certificate", "vault")
    sans = set((cert or {}).get("spec", {}).get("dnsNames", []))
    check(cert and cert["spec"]["secretName"] == "tls-vault" and cert["spec"]["issuerRef"]["name"] == "oj-ca" and "server auth" in cert["spec"]["usages"]
          and {"vault", "vault.oj.svc", "vault.oj.svc.cluster.local", "localhost"} <= sans and "127.0.0.1" in cert["spec"].get("ipAddresses", []),
          f"{label}: tls-vault is signed by oj-ca for the Service names, localhost and 127.0.0.1 (the setup script talks to it from inside the pod)")

    svc, hl = find(objs, "Service", "vault"), find(objs, "Service", "vault-internal")
    check(svc and [p["port"] for p in svc["spec"]["ports"]] == [8200] and svc["spec"].get("type", "ClusterIP") == "ClusterIP", f"{label}: Service vault on 8200, inside the cluster only")
    check(hl and hl["spec"].get("clusterIP") == "None", f"{label}: Service vault-internal is headless")

    crb = find(objs, "ClusterRoleBinding", "vault-auth-delegator")
    check(crb and crb["roleRef"]["name"] == "system:auth-delegator" and crb["subjects"] == [{"kind": "ServiceAccount", "name": "vault", "namespace": "oj"}],
          f"{label}: Vault may review the operator's ServiceAccount tokens (system:auth-delegator) and nothing more")

    np = find(objs, "NetworkPolicy", "allow-to-vault")
    ing = (np or {}).get("spec", {}).get("ingress", [])
    check(np and np["spec"]["podSelector"]["matchLabels"] == {"app": "vault"} and len(ing) == 1 and [p["port"] for p in ing[0]["ports"]] == [8200]
          and [f["namespaceSelector"]["matchLabels"] for f in ing[0]["from"]] == [{"kubernetes.io/metadata.name": "vault-secrets-operator-system"}],
          f"{label}: only the operator's namespace reaches Vault, on 8200 (default-deny covers everything else)")

    conn, auth = find(objs, "VaultConnection", "vault"), find(objs, "VaultAuth", "vault")
    check(conn and conn["spec"]["address"] == "https://vault.oj.svc.cluster.local:8200" and conn["spec"]["caCertSecretRef"] == "tls-vault",
          f"{label}: the operator reaches Vault over TLS and trusts the stack's CA")
    k = (auth or {}).get("spec", {}).get("kubernetes", {})
    check(auth and auth["spec"]["method"] == "kubernetes" and k.get("role") == "vso" and k.get("serviceAccount") == "vso" and k.get("audiences") == ["vault"]
          and find(objs, "ServiceAccount", "vso"), f"{label}: the operator logs in with Kubernetes auth as role vso, ServiceAccount vso, audience vault")

    vss = {o["metadata"]["name"]: o["spec"] for o in objs if o.get("kind") == "VaultStaticSecret"}
    check(set(vss) == set(secret_keys), f"{label}: one VaultStaticSecret for each of the {len(secret_keys)} Secrets env-to-secrets.sh makes", str(set(vss) ^ set(secret_keys)))
    bad_spec = [n for n, s in vss.items() if not (s["mount"] == "kv" and s["type"] == "kv-v2" and s["path"] == n and s["vaultAuthRef"] == "vault"
                and s["destination"] == {"name": n, "create": True, "overwrite": True, "transformation": {"excludeRaw": True}} and re.fullmatch(r"\d+[sm]", s.get("refreshAfter", "")))]
    check(not bad_spec, f"{label}: each reads kv/<name> and writes the Secret of that name (overwrite: it takes over the Secret env-to-secrets.sh made; no extra _raw key), polling", str(bad_spec))
    # what a rotation in Vault restarts: the Deployments that read the Secret, never a database or the MinIO server
    readers = {}
    for o in objs:
        if o.get("kind") == "Deployment":
            for r in pod_refs(o["spec"]["template"]["spec"]): readers.setdefault(r, set()).add(o["metadata"]["name"])
    wrong = {n: (sorted(readers.get(n, ())), sorted(t["name"] for t in s.get("rolloutRestartTargets", [])))
             for n, s in vss.items() if readers.get(n, set()) != {t["name"] for t in s.get("rolloutRestartTargets", [])}
             or any(t["kind"] != "Deployment" for t in s.get("rolloutRestartTargets", []))}
    check(not wrong, f"{label}: a changed Secret restarts exactly the Deployments that read it (a running process keeps its old value)", str(wrong))

chart = find(platform, "HelmChart", "vault-secrets-operator")
check(chart and re.fullmatch(r"\d+\.\d+\.\d+", chart["spec"]["version"]) and chart["spec"]["targetNamespace"] == "vault-secrets-operator-system"
      and chart["spec"]["repo"] == "https://helm.releases.hashicorp.com", "the platform installs the Vault Secrets Operator at an exact chart version into its own namespace")
check(chart and "limits" in chart["spec"].get("valuesContent", "") and "memory" in chart["spec"].get("valuesContent", ""), "the operator's pod has a memory limit")
sys.exit(1 if failed else 0)
PY

# ---- k3s/scripts/vault.sh, against a kubectl that records every call and what it is given on stdin ------------------------------
mkdir -p "$tmp/bin" "$tmp/log"
cat > "$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
n=$(($(cat "$FAKE_LOG/n" 2> /dev/null || echo 0) + 1)); echo $n > "$FAKE_LOG/n"
printf '%s\n' "$*" >> "$FAKE_LOG/argv"
cat > "$FAKE_LOG/stdin.$n"
if [[ -n ${FAKE_FAIL_ON:-} ]] && grep -q -- "$FAKE_FAIL_ON" "$FAKE_LOG/argv" "$FAKE_LOG/stdin.$n"; then echo "Error: Vault is sealed" >&2; exit 2; fi
echo '{"initialized": false}'
SH
chmod +x "$tmp/bin/kubectl"
vault() { rm -rf "$tmp/log"; mkdir -p "$tmp/log"; PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" OJ_DEPLOY_DIR=$tmp bash k3s/scripts/vault.sh "$@"; }
secret_values=$(python3 -I - "$tmp" <<'PY'
import sys
sys.path.insert(0, "k3s/scripts")
import re, secret_map   # every password, secret, token and key of the copied .env files (names like `identity` also name Secrets)
print("\n".join(sorted({v for _, kv in secret_map.secrets(sys.argv[1]) for k, v in kv.items() if re.search(r"PASSWORD|SECRET|TOKEN|KEY", k) and len(v) >= 8})))
PY
)

[[ $(vault seed --dry-run 2> /dev/null | sort) == $(sort "$tmp/secrets.txt") ]] && ok "seed --dry-run lists the same Secrets and keys as env-to-secrets.sh --dry-run, and calls nothing" || bad "seed --dry-run differs from env-to-secrets.sh --dry-run"
[[ ! -e $tmp/log/argv ]] && ok "seed --dry-run makes no kubectl call" || bad "seed --dry-run called kubectl"

if env -u VAULT_TOKEN PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" OJ_DEPLOY_DIR=$tmp bash k3s/scripts/vault.sh seed > /dev/null 2> "$tmp/err"; then bad "seed without VAULT_TOKEN stops"
else [[ ! -e $tmp/log/argv ]] && grep -q VAULT_TOKEN "$tmp/err" && ok "seed without VAULT_TOKEN stops before any kubectl call and names the variable" || bad "seed without VAULT_TOKEN: $(head -2 "$tmp/err")"; fi

VAULT_TOKEN=hvs.test-token-value-1234567890 vault seed > "$tmp/seed.out" 2>&1 && ok "seed writes every Secret" || bad "seed failed: $(head -3 "$tmp/seed.out")"
puts=$(grep -c 'kv put -mount=kv' "$tmp/log/argv" || true)
(( puts == $(wc -l < "$tmp/secrets.txt") )) && ok "seed makes one kv put per Secret ($puts)" || bad "seed made $puts kv puts, not one per Secret"
leak=$(grep -F -f <(printf '%s\n' "$secret_values" "hvs.test-token-value-1234567890") "$tmp/log/argv" "$tmp/seed.out" || true)
[[ -z $leak ]] && ok "no password, secret, key or token is on a command line or in seed's output" || bad "a secret reached a command line or the output: ${leak:0:80}"
first_stdin=$(ls "$tmp"/log/stdin.* | sort -V | head -1)
head -1 "$first_stdin" | grep -qx 'hvs.test-token-value-1234567890' && ok "the token travels on stdin, first line" || bad "the token is not the first stdin line"
# the longest value, identity's JWT signing key (a one-line base64 PEM of about 2.3 KB), must reach Vault unaltered
python3 - "$tmp/log" "$tmp/.env.identity" <<'PY' && ok "the JWT private key reaches Vault intact, as JSON on stdin" || bad "the JWT private key was altered on its way to Vault"
import glob, json, sys
sys.path.insert(0, "k3s/scripts")
import dotenv
want = dotenv.parse(sys.argv[2])["JWT_RSA_PRIVATE_KEY"]
sent = [json.loads(p[1]) for f in glob.glob(sys.argv[1] + "/stdin.*") if len(p := open(f).read().split("\n", 1)) == 2 and "JWT_RSA_PRIVATE_KEY" in p[1]]
sys.exit(0 if len(want) > 1000 and [s["JWT_RSA_PRIVATE_KEY"] for s in sent] == [want] else 1)
PY

if VAULT_TOKEN=hvs.test-token-value-1234567890 FAKE_FAIL_ON=minio-root vault seed > /dev/null 2> "$tmp/err"; then bad "seed stops when Vault refuses a write (sealed)"
else grep -q minio-root "$tmp/err" && ! grep -q 'kv put -mount=kv judge-token' "$tmp/log/argv" \
  && ok "seed stops at the first refused write and names the Secret (the rest are not attempted)" || bad "seed after a refusal: $(head -3 "$tmp/err")"; fi

VAULT_TOKEN=hvs.test-token-value-1234567890 vault configure > "$tmp/conf.out" 2>&1 && ok "configure runs" || bad "configure failed: $(head -3 "$tmp/conf.out")"
policy=$(cat "$tmp"/log/stdin.* | grep -A3 'path "' || true)
[[ $(grep -c 'path "' <<< "$policy") == 1 && $policy == *'path "kv/data/*"'* && $policy == *'capabilities = ["read"]'* ]] \
  && ok "the operator's policy is one rule: read on kv/data/*, no create, update, delete, list or sudo" || bad "the operator's policy: $policy"
grep -q 'auth/kubernetes/role/vso' "$tmp/log/argv" && grep -q 'bound_service_account_names=vso' "$tmp/log/argv" && grep -q 'bound_service_account_namespaces=oj' "$tmp/log/argv" && grep -q 'audience=vault' "$tmp/log/argv" \
  && ok "role vso is bound to the ServiceAccount vso of oj and the audience vault" || bad "configure does not bind role vso as the VaultAuth expects"
grep -q 'audit enable file file_path=stdout' "$tmp/log/argv" && ok "configure turns on the audit log (to the container's stdout)" || bad "configure does not enable the audit device"

vault init > "$tmp/init.out" 2>&1 && grep -q 'operator init -key-shares=5 -key-threshold=3' "$tmp/log/argv" && ok "init splits the unseal key 3 of 5" || bad "init: $(head -3 "$tmp/init.out")"
! grep -rqE '> *[^ ]*(\.env|vault-init|keys)' k3s/scripts/vault.sh && ok "init writes the unseal keys nowhere: they are only printed" || bad "init redirects the keys into a file"
exit $fail
