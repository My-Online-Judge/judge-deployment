#!/usr/bin/env bash
# Proves the probe helpers against throwaway openssl s_servers on a scratch network: a server that requires a client
# certificate and one that does not, a plain HTTP server, and the TLS 1.3 case where a rejected certificate shows up only
# after the handshake. Never touches the live stack.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib/tls-probe.sh
tag=tlsself$$; work=$(mktemp -d)
export OJ_NET=$tag-net TLS_VOLUME=$tag-tls
cleanup() {
  docker --context default rm -f $tag-mtls $tag-open $tag-plain >/dev/null 2>&1
  docker --context default network rm "$OJ_NET" >/dev/null 2>&1
  docker --context default volume rm "$TLS_VOLUME" >/dev/null 2>&1
  docker --context default run --rm -v "$work:/w" alpine:3.22 rm -rf /w/out >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
export PKI_OUT=$work/out
pki/pki.sh init-ca >/dev/null && pki/pki.sh issue edge >/dev/null && pki/pki.sh issue tls-probe >/dev/null && pki/pki.sh rogue >/dev/null || { echo "FAIL pki setup"; exit 1; }
printf 'edge 0:0\ntls-probe 0:0\nrogue 0:0\n' > "$work/ids"
docker --context default network create "$OJ_NET" >/dev/null
docker --context default run --rm -v "$PKI_OUT:/pki:ro" -v "$PWD/pki/install.sh:/install.sh:ro" -v "$work/ids:/identities.txt:ro" \
  -v "$TLS_VOLUME:/tls" --entrypoint /bin/sh alpine:3.22 /install.sh >/dev/null || { echo "FAIL install"; exit 1; }

serve() { # <name> <extra s_server args...>
  local n=$1; shift
  docker --context default run -d --name "$n" --network "$OJ_NET" \
    --mount "type=volume,src=$TLS_VOLUME,dst=/t,readonly,volume-subpath=edge" "$PROBE_IMAGE" \
    openssl s_server -accept 4433 -cert /t/tls.crt -key /t/tls.key -CAfile /t/ca.crt -www "$@" >/dev/null
}
serve $tag-mtls -Verify 1 -verify_return_error -tls1_3
serve $tag-open -tls1_3
docker --context default run -d --name $tag-plain --network "$OJ_NET" "$PROBE_IMAGE" \
  sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" | nc -l -p 8080; done' >/dev/null
sleep 3

# server that requires a client certificate (TLS 1.3 only: rejection arrives after the handshake)
probe_handshake $tag-mtls:4433 tls-probe ok
probe_handshake $tag-mtls:4433 none fail
probe_handshake $tag-mtls:4433 rogue fail
probe_http https://$tag-mtls:4433/ tls-probe 200
probe_http https://$tag-mtls:4433/ none none
# server that does not ask for one: presenting nothing or a foreign cert is accepted, so the helper must say ok
probe_handshake $tag-open:4433 none ok
probe_handshake $tag-open:4433 rogue ok
probe_http https://$tag-open:4433/ none 200
# plaintext
probe_plain_refused $tag-mtls:4433
[[ $(_plain_result $tag-plain:8080) == answered ]] && pass "plain HTTP server is reported as answering" || fail "plain HTTP server is reported as answering"
# the raw results, so a helper that always says ok (or always fail) cannot hide behind a matching expectation
[[ $(_handshake_result $tag-mtls:4433 none) == fail && $(_handshake_result $tag-mtls:4433 tls-probe) == ok ]] && pass "handshake results differ with and without a client cert" || fail "handshake results differ with and without a client cert"
tls_probe_exit
