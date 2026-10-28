#!/usr/bin/env bash
# k3s/ (sub-project 15): both overlays render with `kubectl kustomize`, every object passes kubeconform (a custom resource
# whose schema is not published is skipped), and the stack's invariants hold on what is rendered. Needs the network for the
# pinned tool images and for kubeconform's schemas (it fetches them from GitHub). Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
kubeconform=ghcr.io/yannh/kubeconform:v0.7.0
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}   # the repo's convention is the host's `default` daemon; another machine overrides it
docker --context "$ctx" pull -q "$kubeconform" > /dev/null
docker --context "$ctx" pull -q "$yq" > /dev/null
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
q() { docker --context "$ctx" run --rm -i --network none "$yq" "$@"; }   # q <yq expression> < rendered yaml

# The cluster add-ons (cert-manager, KEDA): installed once, before the stack, by K3s's own Helm controller.
if [[ -f k3s/platform/kustomization.yaml ]]; then
  if platform=$(kubectl kustomize k3s/platform 2> /dev/null); then ok "platform renders"; else bad "platform renders"; platform=''; fi
  if [[ -n $platform ]]; then
    if out=$(docker --context "$ctx" run --rm -i "$kubeconform" -strict -ignore-missing-schemas -summary - <<< "$platform" 2>&1); then
      ok "platform: every object is valid ($(tail -1 <<< "$out"))"
    else bad "platform: kubeconform: $out"; fi
    [[ $(q 'select(.kind == "HelmChart") | .spec.chart' <<< "$platform" | grep -v '^---' | grep -c cert-manager) == 1 ]] \
      && ok "platform installs cert-manager" || bad "platform has no cert-manager chart"
    [[ -z $(q 'select(.kind == "HelmChart") | select(.spec.version | test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$") | not) | .metadata.name' <<< "$platform") ]] \
      && ok "platform pins every chart to an exact version" || bad "platform has a chart without an exact version"
  fi
else bad "k3s/platform/kustomization.yaml exists"; fi

# Kinds that live outside a namespace.
cluster_scoped='Namespace|ClusterIssuer|ClusterRole|ClusterRoleBinding|CustomResourceDefinition|StorageClass|PriorityClass'

for overlay in local vps vps-stage1; do
  dir=k3s/overlays/$overlay
  if [[ ! -f $dir/kustomization.yaml ]]; then bad "$overlay: $dir/kustomization.yaml exists"; continue; fi
  if ! rendered=$(kubectl kustomize "$dir" 2> /tmp/oj-k3s-render.$$); then
    bad "$overlay renders: $(head -3 /tmp/oj-k3s-render.$$)"; continue
  fi
  ok "$overlay renders"
  if out=$(docker --context "$ctx" run --rm -i "$kubeconform" -strict -ignore-missing-schemas -summary - <<< "$rendered" 2>&1); then
    ok "$overlay: every object is valid ($(tail -1 <<< "$out"))"
  else bad "$overlay: kubeconform: $out"; fi
  if [[ $(q 'select(.kind == "Namespace") | .metadata.name' <<< "$rendered") == oj ]]; then ok "$overlay: the namespace oj is created"
  else bad "$overlay: no Namespace oj"; fi
  certs=$(q 'select(.kind == "Certificate") | .metadata.name' <<< "$rendered" | grep -vc '^---' || true)
  if ((certs >= 20)); then ok "$overlay: the Certificates of the identities are there ($certs)"; else bad "$overlay: only $certs Certificates"; fi
  [[ $(q 'select(.kind == "Issuer" and .metadata.name == "oj-ca") | .spec.ca.secretName' <<< "$rendered" | grep -v '^---') == oj-ca ]] \
    && ok "$overlay: the Issuer oj-ca signs with the Secret oj-ca" || bad "$overlay: no Issuer oj-ca"
  stray=$(q "select(.kind | test(\"^($cluster_scoped)\$\") | not) | select(.metadata.namespace != \"oj\") | .kind + \"/\" + .metadata.name" <<< "$rendered")
  if [[ -z $stray ]]; then ok "$overlay: every namespaced object is in oj"; else bad "$overlay: outside the namespace oj: $stray"; fi
done
rm -f /tmp/oj-k3s-render.$$
exit $fail
