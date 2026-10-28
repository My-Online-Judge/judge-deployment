#!/usr/bin/env bash
# k3s/base/pki (sub-project 15): one cert-manager Certificate per identity of pki/identities.txt, generated from it so the
# two cannot drift, each shaped as pki.sh issues a leaf (CN = the identity, server and client auth, PKCS8 key, a year, the
# same CA). Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
yq=mikefarah/yq:4.44.3
ctx=${OJ_DOCKER_CONTEXT:-default}
docker --context "$ctx" pull -q "$yq" > /dev/null
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
q() { docker --context "$ctx" run --rm -i --network none "$yq" "$@"; }

file=k3s/base/pki/certificates.yaml
gen=k3s/scripts/gen-certificates.sh
[[ -f $file && -x $gen ]] || { bad "$file and $gen exist"; exit 1; }

if diff <("$gen") "$file" > /tmp/oj-k3s-pki.$$; then ok "certificates.yaml is what $gen makes from pki/identities.txt"
else bad "certificates.yaml differs from the generator's output (run: $gen > $file):"; sed 's/^/     /' /tmp/oj-k3s-pki.$$ | head -8; fi
rm -f /tmp/oj-k3s-pki.$$

# Every identity pki.sh issues (all but the rogue test CA) has its Certificate, and there are no others.
want=$(awk '$1 !~ /^#/ && NF && $1 != "rogue" { print $1 }' pki/identities.txt | sort)
have=$(q '.spec.commonName' < "$file" | grep -v '^---' | sort)
if [[ $want == "$have" ]]; then ok "a Certificate for each of the $(wc -l <<< "$want" | tr -d ' ') identities, and no other"
else bad "identities and Certificates differ: $(diff <(echo "$want") <(echo "$have") | tr '\n' ' ')"; fi

shape() { # shape <description> <yq expression that must print true for every Certificate>
  if [[ $(q "[$2] | all" < "$file" | grep -v '^---' | sort -u) == true ]]; then ok "$1"; else bad "$1"; fi
}
shape "the secret is tls-<identity>, the CN the identity and the issuer the CA Issuer oj-ca" \
  '.spec.secretName == "tls-" + .spec.commonName and .spec.issuerRef.name == "oj-ca" and .spec.issuerRef.kind == "Issuer"'
shape "server and client auth, as pki.sh's leaves" \
  '(.spec.usages | contains(["server auth", "client auth"]))'
shape "a PKCS8 RSA-2048 key (Java and Kafka read PKCS8 PEM), rotated at every renewal" \
  '.spec.privateKey.algorithm == "RSA" and .spec.privateKey.size == 2048 and .spec.privateKey.encoding == "PKCS8" and .spec.privateKey.rotationPolicy == "Always"'
shape "valid a year, renewed 30 days ahead (pki.sh: 365 days)" \
  '.spec.duration == "8760h" and .spec.renewBefore == "720h"'
shape "named by its service and localhost, as pki.sh's SANs" \
  '.spec as $s | ($s.dnsNames | contains([$s.commonName, $s.commonName + ".oj.svc", $s.commonName + ".oj.svc.cluster.local", "localhost"]))'

[[ $(q 'select(.spec.commonName == "edge") | .spec.dnsNames | contains(["edge"])' < "$file" | grep -v '^---') == true ]] \
  && ok "the edge identity (Traefik's client certificate, CN=edge) names edge" || bad "edge lacks its SAN"
grep -qE '^keda ' pki/identities.txt && ok "keda is an identity (KEDA's client certificate for Kafka)" || bad "pki/identities.txt has no keda"
exit $fail
