#!/usr/bin/env bash
# Waits until the given CustomResourceDefinitions exist and are established: the step between `kubectl apply -k k3s/platform` and
# `kubectl apply -k k3s/overlays/...`. K3s's Helm controller installs cert-manager and KEDA a minute after the HelmChart objects are
# applied, and `kubectl wait` on an object that does not exist yet fails at once instead of waiting.
#   k3s/scripts/wait-for-crds.sh [timeout-seconds [crd/<name>...]]
# Default: 300 seconds, for the CRDs the stack needs (cert-manager's Certificate and Issuer, KEDA's ScaledObject).
# WAIT_INTERVAL: seconds between asking (default 3; the test uses a fraction).
set -euo pipefail
timeout=${1:-300}
shift || true
crds=("$@")
((${#crds[@]} > 0)) || crds=(crd/certificates.cert-manager.io crd/issuers.cert-manager.io crd/scaledobjects.keda.sh)
interval=${WAIT_INTERVAL:-3}
deadline=$((SECONDS + timeout))
for crd in "${crds[@]}"; do
  until kubectl get "$crd" > /dev/null 2>&1; do
    if ((SECONDS >= deadline)); then echo "wait-for-crds.sh: $crd does not exist after ${timeout}s (is the platform installed? kubectl -n kube-system get helmchart)" >&2; exit 1; fi
    sleep "$interval"
  done
  kubectl wait --for condition=established "$crd" --timeout="$((deadline > SECONDS ? deadline - SECONDS : 1))s"
done
echo "CRDs ready: ${crds[*]}"
