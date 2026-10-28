#!/usr/bin/env bash
# The server: load the compose stack's CA (pki/out/ca) as the Secret oj-ca, so cert-manager's certificates chain to the CA
# every client already trusts and the cutover changes no trust. Idempotent. (overlays/local makes its own CA instead.)
set -euo pipefail
cd "$(dirname "$0")/../.."
for f in pki/out/ca/ca.crt pki/out/ca/ca.key; do [[ -f $f ]] || { echo "ca-from-pki.sh: $f is missing: run pki/pki.sh init-ca" >&2; exit 1; }; done
kubectl get namespace oj > /dev/null 2>&1 || kubectl create namespace oj
kubectl -n oj create secret generic oj-ca --type=kubernetes.io/tls \
  --from-file=tls.crt=pki/out/ca/ca.crt --from-file=tls.key=pki/out/ca/ca.key \
  --dry-run=client -o yaml | kubectl apply -f -
