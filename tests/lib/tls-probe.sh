#!/usr/bin/env bash
# TLS probe helpers (sub-project 10). Source this file; every probe is a throwaway container on ${OJ_NET:-oj-net}.
#   probe_handshake <host:port> <none|tls-probe|rogue> <ok|fail> [starttls-proto] [verify-hostname]
#     a probe that could not connect at all is `error`, which matches no expectation
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

# _classify_handshake <s_client output> -> ok|fail|error
#   error: no TCP connection was made (or docker itself failed): the output has no CONNECTED(. Matches no expectation.
#   ok:    verified chain (Verify return code: 0) and no alert. A server that drops a non-TLS line without close_notify
#          ("unexpected eof") is still ok; an alert, including TLS 1.3's post-handshake certificate_required, is fail.
_classify_handshake() {
  grep -q 'CONNECTED(' <<< "$1" || { echo error; return; }
  if grep -q 'Verify return code: 0 (ok)' <<< "$1" && ! grep -v 'unexpected eof' <<< "$1" | grep -qE 'alert (read|write)|:error:'; then echo ok; else echo fail; fi
}

# _handshake_result <host:port> <who> [starttls-protocol] [verify-hostname] -> prints ok|fail|error
_handshake_result() {
  local extra="" out
  [[ -n ${3:-} ]] && extra="$extra -starttls $3"
  [[ -n ${4:-} ]] && extra="$extra -verify_hostname $4"
  out=$(_probe_run "$2" "(printf 'GET / HTTP/1.0\r\n\r\n'; sleep 1) | timeout 10 openssl s_client -connect '$1' -servername '${1%:*}' -CAfile /t/ca.crt -verify_return_error$extra \$CERT_ARGS 2>&1")
  _classify_handshake "$out"
}

probe_handshake() { # <host:port> <none|tls-probe|rogue> <ok|fail> [starttls-protocol e.g. postgres] [verify-hostname]
  local got; got=$(_handshake_result "$1" "$2" "${4:-}" "${5:-}")
  if [[ $got == "$3" ]]; then pass "handshake $1 as $2 -> $3"; else fail "handshake $1 as $2: wanted $3, got $got"; fi
}

# _http_status <https-url> <who> -> prints the status code or "none"
_http_status() {
  local url=${1#https://} hostport path out
  hostport=${url%%/*}; path=/${url#*/}; [[ $url == */* ]] || path=/
  [[ $hostport == *:* ]] || hostport=$hostport:443
  out=$(_probe_run "$2" "(printf 'GET $path HTTP/1.1\r\nHost: ${hostport%:*}\r\nConnection: close\r\n\r\n'; sleep 1) | timeout 10 openssl s_client -connect '$hostport' -servername '${hostport%:*}' -CAfile /t/ca.crt -verify_return_error \$CERT_ARGS 2>&1")
  grep -q 'CONNECTED(' <<< "$out" || { echo error; return; }
  out=$(grep -m1 -E '^HTTP/[0-9.]+ [0-9]{3}' <<< "$out" | tr -d '\r' | awk '{print $2}')
  echo "${out:-none}"
}

probe_http() { # <https-url> <tls-probe|none> <expected-status|none>
  local got; got=$(_http_status "$1" "$2")
  if [[ $got == "$3" ]]; then pass "GET $1 as $2 -> $3"; else fail "GET $1 as $2: wanted $3, got $got"; fi
}

# _plain_result <host:port> -> prints refused|answered|error (error: the TCP connect itself failed)
_plain_result() {
  local out
  out=$(docker --context default run --rm --network "${OJ_NET:-oj-net}" "$PROBE_IMAGE" sh -c "nc -z -w 3 ${1%:*} ${1#*:} || { echo NOCONNECT; exit 0; }; printf 'GET / HTTP/1.0\r\n\r\n' | timeout 5 nc -w 3 ${1%:*} ${1#*:} 2>&1; echo DONE" 2>&1)
  if ! grep -q DONE <<< "$out"; then echo error
  elif grep -q 'HTTP/' <<< "$out"; then echo answered
  else echo refused; fi
}

probe_plain_refused() { # <host:port>
  local got; got=$(_plain_result "$1")
  case $got in
    refused) pass "plaintext to $1 gets no HTTP answer" ;;
    answered) fail "plaintext to $1 was answered over HTTP" ;;
    *) fail "plaintext to $1: no TCP connection, nothing proved" ;;
  esac
}
