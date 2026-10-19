#!/usr/bin/env bash
# Proves the probe helpers against throwaway openssl s_servers on a scratch network: a server that requires a client
# certificate and one that does not, a plain HTTP server, a silent plaintext server that just hangs up, a stand-in for
# Tomcat's fixed answer to plaintext on a TLS port, and the TLS 1.3 case where a rejected certificate shows up only after
# the handshake. Never touches the live stack.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/lib/tls-probe.sh
tag=tlsself$$; work=$(mktemp -d)
export OJ_NET=$tag-net TLS_VOLUME=$tag-tls
cleanup() {
  docker --context default rm -f $tag-mtls $tag-open $tag-plain $tag-silent $tag-tlsonly >/dev/null 2>&1
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
# plaintext that answers nothing and hangs up (a Kafka PLAINTEXT listener dropping the ClientHello): no TLS bytes at all
docker --context default run -d --name $tag-silent --network "$OJ_NET" "$PROBE_IMAGE" \
  sh -c 'while true; do nc -l -p 9092 </dev/null >/dev/null; done' >/dev/null
# Tomcat's answer to plaintext on its TLS port (TLSClientHelloExtractor.USE_TLS_RESPONSE), byte for byte
docker --context default run -d --name $tag-tlsonly --network "$OJ_NET" "$PROBE_IMAGE" \
  sh -c 'while true; do printf "HTTP/1.1 400 \r\nContent-Type: text/plain;charset=UTF-8\r\nConnection: close\r\n\r\nBad Request\r\nThis combination of host and port requires TLS.\r\n" | nc -l -p 8443; done' >/dev/null
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
# Tomcat writes its fixed 400 before reading any request: the API was not served, so that is a refusal
[[ $(_plain_result $tag-tlsonly:8443) == refused ]] && pass "Tomcat's 'requires TLS' 400 is reported as refused" || fail "Tomcat's 'requires TLS' 400 is reported as refused (got $(_plain_result $tag-tlsonly:8443))"
# the raw results, so a helper that always says ok (or always fail) cannot hide behind a matching expectation
[[ $(_handshake_result $tag-mtls:4433 none) == fail && $(_handshake_result $tag-mtls:4433 tls-probe) == ok ]] && pass "handshake results differ with and without a client cert" || fail "handshake results differ with and without a client cert"
# hostname verification
probe_handshake $tag-open:4433 tls-probe ok "" edge
probe_handshake $tag-open:4433 tls-probe fail "" not-the-name
# no connection at all is `error`, never ok/fail/refused
[[ $(_handshake_result $tag-nohost:4433 none) == error ]] && pass "unreachable host -> error" || fail "unreachable host -> error"
[[ $(_handshake_result $tag-open:4999 tls-probe) == error ]] && pass "closed port -> error" || fail "closed port -> error"
[[ $(_plain_result $tag-nohost:4433) == error && $(_plain_result $tag-open:4999) == error ]] && pass "plain probe: unreachable and closed port -> error" || fail "plain probe: unreachable and closed port -> error"
[[ $(_http_status https://$tag-open:4999/ none) == error ]] && pass "http probe: closed port -> error" || fail "http probe: closed port -> error"
# classification of a server that drops the line without close_notify (Kafka-like): still ok; an alert is fail
c_ok=$'CONNECTED(00000003)\nVerify return code: 0 (ok)\n40:error:0A000126:SSL routines::unexpected eof while reading'
c_alert=$'CONNECTED(00000003)\nVerify return code: 0 (ok)\n40:error:0A00045C:SSL routines::tlsv13 alert certificate required:SSL alert number 116'
[[ $(_classify_handshake "$c_ok") == ok && $(_classify_handshake "$c_alert") == fail && $(_classify_handshake "x") == error ]] && pass "classifier: unexpected eof ok, alert fail, no CONNECTED error" || fail "classifier cases"
# a plaintext server that hangs up: no certificate ever arrived, yet s_client reports verify code 0 -> error, never ok
c_silent=$'CONNECTED(00000003)\n40:error:0A000126:SSL routines::unexpected eof while reading\n---\nno peer certificate available\n---\nVerify return code: 0 (ok)'
[[ $(_classify_handshake "$c_silent") == error ]] && pass "classifier: no peer certificate with verify code 0 -> error" || fail "classifier: no peer certificate with verify code 0 -> error (got $(_classify_handshake "$c_silent"))"
[[ $(_handshake_result $tag-silent:9092 tls-probe) == error && $(_handshake_result $tag-silent:9092 none) == error ]] && pass "silent plaintext server -> error with and without a client cert" || fail "silent plaintext server -> error with and without a client cert (got $(_handshake_result $tag-silent:9092 tls-probe)/$(_handshake_result $tag-silent:9092 none))"
# the same server for the HTTP probe: no HTTP answer, but no TLS either -> error, never `none` (which `probe_http … none none` accepts)
[[ $(_http_status https://$tag-silent:9092/ tls-probe) == error && $(_http_status https://$tag-silent:9092/ none) == error ]] && pass "http probe: silent plaintext server -> error with and without a client cert" || fail "http probe: silent plaintext server -> error with and without a client cert (got $(_http_status https://$tag-silent:9092/ tls-probe)/$(_http_status https://$tag-silent:9092/ none))"
# NOT self-tested: -starttls postgres (openssl s_server cannot speak the postgres SSLRequest); it is used by the Postgres task.
tls_probe_exit
