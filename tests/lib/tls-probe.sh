#!/usr/bin/env bash
# TLS probe helpers (sub-project 10). Source this file; every probe is a throwaway container on ${OJ_NET:-oj-net}.
#   probe_handshake <host:port> <none|tls-probe|rogue> <ok|fail>
#   probe_http <https-url> <tls-probe|none> <expected-status|none>     (none = no HTTP answer at all)
#   probe_plain_refused <host:port>
# Certificates come from ${TLS_VOLUME:-judge-deployment_tls}: the tls-probe/ subpath (CA + probe leaf) or rogue/ (our CA
# for the server side, a leaf from a foreign CA). Mode none presents no client certificate.
# TLS 1.3 reports a rejected client certificate only after the handshake, so every probe sends a request and reads.
# pass/fail count; finish with `tls_probe_exit`.

PROBE_IMAGE=${PROBE_IMAGE:-eclipse-temurin:17-jre-alpine}
probe_pass=0 probe_fail=0
pass() { probe_pass=$((probe_pass + 1)); echo "ok   $1"; }
fail() { probe_fail=$((probe_fail + 1)); echo "FAIL $1"; }
tls_probe_exit() { echo; echo "tls probes: $probe_pass passed, $probe_fail failed"; return $((probe_fail > 0)); }

# _probe_run <none|tls-probe|rogue> <sh script> : runs the script; $CERT_ARGS is "-cert .. -key .." when a cert is presented
_probe_run() {
  local who=$1 script=$2 sub=tls-probe args=""
  [[ $who == rogue ]] && sub=rogue
  [[ $who != none ]] && args="-cert /t/tls.crt -key /t/tls.key"
  docker --context default run --rm --network "${OJ_NET:-oj-net}" \
    --mount "type=volume,src=${TLS_VOLUME:-judge-deployment_tls},dst=/t,readonly,volume-subpath=$sub" \
    -e CERT_ARGS="$args" "$PROBE_IMAGE" sh -c "$script" 2>&1
}

# _handshake_result <host:port> <who> -> prints ok|fail
_handshake_result() {
  local out
  out=$(_probe_run "$2" "(printf 'GET / HTTP/1.0\r\n\r\n'; sleep 1) | timeout 10 openssl s_client -connect '$1' -servername '${1%:*}' -CAfile /t/ca.crt -verify_return_error \$CERT_ARGS 2>&1")
  if grep -q 'Verify return code: 0 (ok)' <<< "$out" && ! grep -qE 'alert (read|write)|:error:|unexpected eof|SSL_read|errno=' <<< "$out"; then echo ok; else echo fail; fi
}

probe_handshake() { # <host:port> <none|tls-probe|rogue> <ok|fail>
  local got; got=$(_handshake_result "$1" "$2")
  if [[ $got == "$3" ]]; then pass "handshake $1 as $2 -> $3"; else fail "handshake $1 as $2: wanted $3, got $got"; fi
}

# _http_status <https-url> <who> -> prints the status code or "none"
_http_status() {
  local url=${1#https://} hostport path out
  hostport=${url%%/*}; path=/${url#*/}; [[ $url == */* ]] || path=/
  [[ $hostport == *:* ]] || hostport=$hostport:443
  out=$(_probe_run "$2" "(printf 'GET $path HTTP/1.1\r\nHost: ${hostport%:*}\r\nConnection: close\r\n\r\n'; sleep 1) | timeout 10 openssl s_client -quiet -connect '$hostport' -servername '${hostport%:*}' -CAfile /t/ca.crt -verify_return_error \$CERT_ARGS 2>/dev/null")
  out=$(grep -m1 -E '^HTTP/[0-9.]+ [0-9]{3}' <<< "$out" | tr -d '\r' | awk '{print $2}')
  echo "${out:-none}"
}

probe_http() { # <https-url> <tls-probe|none> <expected-status|none>
  local got; got=$(_http_status "$1" "$2")
  if [[ $got == "$3" ]]; then pass "GET $1 as $2 -> $3"; else fail "GET $1 as $2: wanted $3, got $got"; fi
}

# _plain_result <host:port> -> prints refused|answered
_plain_result() {
  local out
  out=$(docker --context default run --rm --network "${OJ_NET:-oj-net}" "$PROBE_IMAGE" sh -c "printf 'GET / HTTP/1.0\r\n\r\n' | timeout 5 nc -w 3 ${1%:*} ${1#*:} 2>&1")
  if grep -q 'HTTP/' <<< "$out"; then echo answered; else echo refused; fi
}

probe_plain_refused() { # <host:port>
  local got; got=$(_plain_result "$1")
  if [[ $got == refused ]]; then pass "plaintext to $1 gets no HTTP answer"; else fail "plaintext to $1 was answered over HTTP"; fi
}
