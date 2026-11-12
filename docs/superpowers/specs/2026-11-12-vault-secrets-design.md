# Secrets in HashiCorp Vault (server overlays)

Date: 2026-11-12. Status: built and rehearsed on a throwaway k3d cluster; not yet on the server (it lands with the cutover, k3s/README.md
"Cutover from compose").

## Why

Until now the stack's secrets lived in plain `.env*` files on the deploy host, turned into Kubernetes Secrets by
`k3s/scripts/env-to-secrets.sh`. There was no single store, no audit trail and no rotation path short of editing a file and re-running the
script. The owner asked for HashiCorp Vault and left the design choices to us ("use sensible defaults"). The choices below are ours, marked
as such so they can be revisited.

## Decisions

1. **Self-hosted Vault in the cluster, one node** (`k3s/components/vault`): Raft storage on a 1Gi claim, TLS from the stack's own CA
   (`Certificate vault` -> `tls-vault`, issuer `oj-ca`), image pinned to an exact release. Our call: a single VPS has no second node and no
   cloud KMS; HCP Vault would add an outside dependency and cost.
2. **The Vault Secrets Operator writes the same Secrets** (`k3s/platform/vault-secrets-operator.yaml`, chart pinned): one
   `VaultStaticSecret` per Secret of `secret_map.py`, same name, same keys (`excludeRaw: true`, so no `_raw` key), `overwrite: true` so it
   takes over a Secret `env-to-secrets.sh` made. Our call: no workload, no service code and no sibling repo changes. The alternatives (the
   Vault Agent injector, Spring Cloud Vault in four Java services plus the Go server) change every consumer.
3. **Server overlays only.** `overlays/vps` adds the component, and `vps-stage1` inherits it. `base` and `overlays/local` (k3d, CI) keep
   `env-to-secrets.sh`. Compose keeps its `.env` files. Our call: CI and every k3s test depend on the script, and compose is being retired.
4. **One table.** `k3s/scripts/secret_map.py` holds the Secret -> `.env` keys mapping that was inside `env-to-secrets.sh`; that script,
   `vault.sh seed` and `gen_vault.py` all read it. `tests/k3s-vault.test.sh` checks that the generated `secrets.yaml` matches it, and that
   `seed --dry-run` lists the same names and keys as `env-to-secrets.sh --dry-run`.
5. **Manual Shamir unseal, three of five shares**, held by the owner offline. The root token is revoked after setup and regenerated with
   `vault operator generate-root` when needed. Our call: auto-unseal needs a cloud KMS or a second Vault. The cost is that Vault is sealed
   after every restart of `vault-0`. While it is sealed, existing Secrets and running pods are unaffected; only changes wait.
6. **Least privilege.** The operator logs in with Kubernetes auth (role `vso`, ServiceAccount `vso` of `oj`, audience `vault`) and its policy is
   `read` on `kv/data/*`, nothing else. Vault's own ServiceAccount has `system:auth-delegator` (TokenReview) only. NetworkPolicy
   `allow-to-vault` admits the operator's namespace on 8200; default-deny covers the rest. The audit device writes to Vault's stdout.
7. **Restart on rotation.** Each `VaultStaticSecret` lists, as `rolloutRestartTargets`, exactly the Deployments that read its Secret
   (`RESTART` in `gen_vault.py`; the test derives the readers from the rendered overlay). StatefulSets are never restarted: a changed
   `POSTGRES_PASSWORD` or `MINIO_ROOT_PASSWORD` in the environment does not change the stored password. `vps-stage1` patches the judge
   pods out of the targets because it has no judge pods.
8. **The token and the values never go on a command line.** `vault.sh` runs the Vault CLI through `kubectl exec`, sending the token as the
   first stdin line and each Secret as JSON after it. `init` prints the shares once and writes them nowhere.
9. **Vault is the source after the seed; `.env*` is the backup.** `seed` rewrites every value from `.env`, so a rotation made only in Vault is
   reverted by the next `seed`. A rotation therefore goes into `.env` too. Vault's Raft data is not in the nightly restic snapshot; recovery is
   a fresh Vault plus `seed` from the `.env*` copy that k3s/README.md "Backup and restore" already asks the owner to keep.

## Not in scope (v1)

- TLS keys: cert-manager keeps issuing `tls-*`, `oj-ca` and `edge-tls`.
- Dynamic database credentials (Vault's database engine).
- The GitHub Actions secrets (`DOCKERHUB_TOKEN`).
- Compose and `overlays/local`, which keep `.env` and `env-to-secrets.sh` (decision 3).
- Encryption at rest of Secrets in etcd (K3s `--secrets-encryption`); Vault does not provide it, since the operator writes ordinary Secrets.
- Automated Vault snapshots in the nightly backup (decision 9).

## Failure behaviour (rehearsed on k3d unless noted)

| Situation | What happens |
|---|---|
| Vault sealed (restart, reboot) | `vault-0` is 0/1; the Secrets stay; running pods continue; `seed` stops at the first Secret with "Vault is sealed" and writes none after it |
| A Secret's path missing in Vault (not rehearsed) | The operator does not create it; the pods that need it wait, as they wait today when `env-to-secrets.sh` has not run (rehearsed: pods waiting until `seed` ran) |
| `seed` without `VAULT_TOKEN` | Stops before any call and names the variable |
| `.env` file or required key missing | `seed` and `env-to-secrets.sh` stop with the same message (shared `secret_map.py`) |
| Another pod of `oj` connects to Vault | Refused by the network policy (rehearsed: a pod in `oj` blocked, a pod in the operator's namespace reached) |
| Value changed in Vault | Secret rewritten within `refreshAfter` (60s); its Deployments restarted (rehearsed: about 15s) |
| Long value (2.3 KB base64 JWT key) | Reaches Vault and the Secret unaltered (rehearsed; also in the test) |
