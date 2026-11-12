#!/usr/bin/env bash
# Vault on the server (k3s/components/vault): the steps a person runs, through `kubectl exec` into vault-0, so no Vault CLI is needed here.
#   k3s/scripts/vault.sh init               once: split the unseal key 3 of 5 and print the shares and the root token (kept nowhere else)
#   k3s/scripts/vault.sh configure          the audit log, the kv mount, Kubernetes auth and the operator's read-only role (idempotent)
#   k3s/scripts/vault.sh seed [--dry-run]   write the .env files into kv/<Secret>, by the table in secret_map.py (again after a change);
#                                           --dry-run prints each Secret's name and keys, never a value, and calls nothing
# Unsealing is by hand, three shares: `kubectl -n oj exec -it vault-0 -- vault operator unseal` asks for one share each time.
# configure and seed need VAULT_TOKEN (the root token at first); it reaches Vault on stdin, never as an argument, and so does every value.
# OJ_DEPLOY_DIR: the directory of the .env files (default judge-deployment; tests use a copy).
set -euo pipefail
dir=${OJ_DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
# inside the pod: the token is stdin's first line, the rest of stdin goes on to vault
export VAULT_EXEC_SH='IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"'
vexec() { kubectl -n oj exec -i vault-0 -c vault -- sh -c "$VAULT_EXEC_SH" sh "$@"; }
v() { printf '%s\n' "${VAULT_TOKEN:-}" | vexec "$@"; }
once() { local out; out=$(v "$@" 2>&1) || grep -q 'already in use' <<< "$out" || { echo "$out" >&2; exit 1; }; }   # an enable done before is fine
need_token() { [[ -n ${VAULT_TOKEN:-} ]] || { echo "vault.sh: $1 needs VAULT_TOKEN (the root token at first: read -rs VAULT_TOKEN && export VAULT_TOKEN)" >&2; exit 2; }; }

case ${1:-} in
  init)
    status=$(v status -format=json 2> /dev/null || true)   # exits 2 while sealed
    if grep -q '"initialized": true' <<< "$status"; then echo "vault.sh: Vault is initialized already"; exit 0; fi
    echo "vault.sh: the five unseal key shares (any three unseal Vault) and the root token follow, once: store them apart, offline." >&2
    v operator init -key-shares=5 -key-threshold=3
    ;;
  configure)
    need_token configure
    once audit enable file file_path=stdout
    once secrets enable -path=kv -version=2 kv
    once auth enable kubernetes
    v write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443 > /dev/null
    { printf '%s\n' "$VAULT_TOKEN" 'path "kv/data/*" {' '  capabilities = ["read"]' '}'; } | vexec policy write vso - > /dev/null
    v write auth/kubernetes/role/vso bound_service_account_names=vso bound_service_account_namespaces=oj audience=vault policies=vso token_ttl=1h > /dev/null
    echo "vault.sh: configured: audit log on Vault's stdout, kv/ (version 2), Kubernetes auth, role vso (ServiceAccount vso of oj) reading kv/data/*"
    ;;
  seed)
    dry=0
    case ${2:-} in --dry-run) dry=1 ;; '') need_token seed ;; *) echo "usage: $0 seed [--dry-run]" >&2; exit 2 ;; esac
    PYTHONPATH=$(dirname "${BASH_SOURCE[0]}") python3 - "$dir" "$dry" <<'PY'
import json, os, subprocess, sys
import secret_map   # k3s/scripts/secret_map.py: which .env keys make which Secret (env-to-secrets.sh reads the same table)
dir_, dry = sys.argv[1], sys.argv[2] == "1"
try:
    for name, values in secret_map.secrets(dir_):
        if dry:
            print(name, ",".join(sorted(values)))
            continue
        r = subprocess.run(["kubectl", "-n", "oj", "exec", "-i", "vault-0", "-c", "vault", "--", "sh", "-c", os.environ["VAULT_EXEC_SH"], "sh",
                            "kv", "put", "-mount=kv", name, "-"],
                           input=os.environ["VAULT_TOKEN"] + "\n" + json.dumps(values), capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"vault.sh: Vault did not take kv/{name} (the Secrets after it are not written): {r.stderr.strip()}")
        print(f"seeded kv/{name} ({len(values)} keys)")
except ValueError as e:
    sys.exit(f"vault.sh: {e}")
PY
    ;;
  *) echo "usage: $0 init | configure | seed [--dry-run]" >&2; exit 2 ;;
esac
