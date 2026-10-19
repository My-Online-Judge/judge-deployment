#!/usr/bin/env bash
# pki/pki.sh, pki/install.sh and the compose tls-mount rules (sub-project 10, task 1). Needs host openssl and docker.
set -uo pipefail
cd "$(dirname "$0")/.."
pki=$PWD/pki/pki.sh
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export PKI_OUT=$work/out
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { # check <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
has() { grep -q -- "$1" <<< "$2"; }

"$pki" init-ca >/dev/null 2>&1 && ok "init-ca" || bad "init-ca"
"$pki" issue foo >/dev/null 2>&1
foo=$PKI_OUT/foo
check "leaf verifies against the CA" openssl verify -CAfile "$PKI_OUT/ca/ca.crt" "$foo/tls.crt"
text=$(openssl x509 -in "$foo/tls.crt" -noout -text 2>/dev/null)
has "DNS:foo" "$text" && has "DNS:localhost" "$text" && has "IP Address:127.0.0.1" "$text" && ok "SAN has id, localhost, 127.0.0.1" || bad "SAN has id, localhost, 127.0.0.1"
has "TLS Web Server Authentication" "$text" && has "TLS Web Client Authentication" "$text" && ok "EKU is serverAuth + clientAuth" || bad "EKU is serverAuth + clientAuth"
has "Subject: CN *= *foo$" "$text" && ok "subject is CN=foo only" || bad "subject is CN=foo only"
has "RSA Public-Key: (2048 bit)\|Public-Key: (2048 bit)" "$text" && ok "RSA-2048" || bad "RSA-2048"
[[ $(head -1 "$foo/tls.key") == "-----BEGIN PRIVATE KEY-----" && $(stat -c %a "$foo/tls.key") == 600 ]] && ok "key is PKCS#8 PEM, mode 600" || bad "key is PKCS#8 PEM, mode 600"
[[ $(grep -c 'BEGIN PRIVATE KEY' "$foo/keystore.pem") == 1 && $(grep -c 'BEGIN CERTIFICATE' "$foo/keystore.pem") == 1 ]] && ok "keystore.pem holds one key and one cert" || bad "keystore.pem holds one key and one cert"
[[ $(stat -c %a "$foo") == 700 && $(stat -c %a "$foo/tls.crt") == 644 ]] && ok "dir 700, cert 644" || bad "dir 700, cert 644"
"$pki" issue minio >/dev/null 2>&1
[[ -f $PKI_OUT/minio/CAs/ca.crt && -f $PKI_OUT/minio/public.crt && -f $PKI_OUT/minio/private.key ]] && ok "minio gets public.crt, private.key, CAs/ca.crt" || bad "minio gets public.crt, private.key, CAs/ca.crt"
"$pki" issue extra 10.1.2.3 oj.example.org >/dev/null 2>&1
t=$(openssl x509 -in "$PKI_OUT/extra/tls.crt" -noout -text); has "IP Address:10.1.2.3" "$t" && has "DNS:oj.example.org" "$t" && ok "extra SANs (ip and dns)" || bad "extra SANs (ip and dns)"

"$pki" rogue >/dev/null 2>&1
if openssl verify -CAfile "$PKI_OUT/ca/ca.crt" "$PKI_OUT/rogue/tls.crt" >/dev/null 2>&1; then bad "rogue leaf fails against our CA"; else ok "rogue leaf fails against our CA"; fi
has "CN *= *tls-probe" "$(openssl x509 -in "$PKI_OUT/rogue/tls.crt" -noout -subject)" && ok "rogue CN is tls-probe" || bad "rogue CN is tls-probe"
"$pki" init-ca >/dev/null 2>&1; [[ $? == 1 ]] && ok "init-ca refuses to overwrite" || bad "init-ca refuses to overwrite"
before=$(openssl x509 -in "$PKI_OUT/ca/ca.crt" -noout -serial)
"$pki" init-ca --force >/dev/null 2>&1; [[ $(openssl x509 -in "$PKI_OUT/ca/ca.crt" -noout -serial) != "$before" ]] && ok "init-ca --force replaces" || bad "init-ca --force replaces"

# issue-all + install.sh in alpine
rm -rf "$PKI_OUT"; "$pki" init-ca >/dev/null 2>&1
OJ_PUBLIC_HOST=oj.example.org "$pki" issue-all >/dev/null 2>&1
t=$(openssl x509 -in "$PKI_OUT/edge/tls.crt" -noout -text); has "DNS:oj.example.org" "$t" && has "DNS:edge" "$t" && ok "edge SANs expand OJ_PUBLIC_HOST" || bad "edge SANs expand OJ_PUBLIC_HOST"
[[ ! -e $PKI_OUT/rogue/tls.crt ]] && ok "issue-all skips rogue" || bad "issue-all skips rogue"
[[ $("$pki" status | wc -l) -ge 19 && $("$pki" status | awk '$1=="edge"{print $2}') -ge 364 ]] && ok "status prints id days serial" || bad "status prints id days serial"

tlsdir=$work/tls; mkdir -p "$tlsdir"
install_run() {
  docker --context default run --rm -v "$PKI_OUT:/pki:ro" -v "$PWD/pki/install.sh:/install.sh:ro" \
    -v "$PWD/pki/identities.txt:/identities.txt:ro" -v "$tlsdir:/tls" --entrypoint /bin/sh alpine:3.22 /install.sh
}
install_run >/dev/null 2>&1 && ok "install.sh succeeds (rogue absent is fine)" || bad "install.sh succeeds (rogue absent is fine)"
st() { docker --context default run --rm -v "$tlsdir:/tls:ro" alpine:3.22 stat -c "$1" "/tls/$2"; }
[[ $(st '%u:%g %a' redis/tls.key) == "999:999 600" ]] && ok "redis key 999:999 600" || bad "redis key 999:999 600"
[[ $(st '%u:%g %a' jaeger/tls.key) == "10001:10001 600" ]] && ok "jaeger key 10001:10001 600" || bad "jaeger key 10001:10001 600"
[[ $(st '%u:%g %a' api-gateway) == "0:0 700" ]] && ok "api-gateway dir 0:0 700" || bad "api-gateway dir 0:0 700"
[[ $(st '%a' api-gateway/tls.crt) == 644 && $(st '%a' kafka/keystore.pem) == 600 && $(st '%a' minio/private.key) == 600 && $(st '%a' minio/CAs) == 700 ]] && ok "cert 644, keystore.pem 600, private.key 600, nested dir 700" || bad "modes of cert, keystore.pem, private.key, nested dir"

# rotation: re-issue (same CA), reinstall, no stale file
"$pki" issue redis >/dev/null 2>&1
docker --context default run --rm -v "$tlsdir:/tls" alpine:3.22 touch /tls/redis/stale >/dev/null 2>&1
install_run >/dev/null 2>&1
new=$(openssl x509 -in "$PKI_OUT/redis/tls.crt" -noout -serial)
inst=$(docker --context default run --rm -v "$tlsdir:/tls:ro" alpine:3.22 cat /tls/redis/tls.crt | openssl x509 -noout -serial)
[[ $new == "$inst" ]] && ok "re-issued leaf is what is installed" || bad "re-issued leaf is what is installed"
[[ -z $(docker --context default run --rm -v "$tlsdir:/tls:ro" alpine:3.22 ls /tls/redis | grep stale) ]] && ok "no stale file after re-install" || bad "no stale file after re-install"
rm -rf "$PKI_OUT/problem-db"
install_run >/dev/null 2>&1; [[ $? != 0 ]] && ok "install.sh fails when a listed id has no source" || bad "install.sh fails when a listed id has no source"
docker --context default run --rm -v "$work:/w" alpine:3.22 rm -rf /w/tls >/dev/null 2>&1

# fixtures
"$pki" fixtures "$work/fx" >/dev/null 2>&1
n=0; for f in ca.crt server.crt server.key api-gateway.crt api-gateway.key submission-service.crt submission-service.key edge.crt edge.key tls-probe.crt tls-probe.key rogue-ca.crt rogue-client.crt rogue-client.key; do [[ -f $work/fx/$f ]] && n=$((n + 1)); done
[[ $n == 14 ]] && ok "fixtures writes the full set" || bad "fixtures writes the full set ($n of 14)"
check "fixture leaf verifies against fixture CA" openssl verify -CAfile "$work/fx/ca.crt" "$work/fx/server.crt"
has "CN *= *localhost" "$(openssl x509 -in "$work/fx/server.crt" -noout -subject)" && ok "fixture server CN is localhost" || bad "fixture server CN is localhost"
openssl verify -CAfile "$work/fx/ca.crt" "$work/fx/rogue-client.crt" >/dev/null 2>&1 && bad "rogue-client fails against fixture CA" || ok "rogue-client fails against fixture CA"
has "notAfter=.*20[3-9][0-9]" "$(openssl x509 -in "$work/fx/ca.crt" -noout -enddate)" && ok "fixtures valid ~10 years" || bad "fixtures valid ~10 years"

# compose rules (generic tls-mount loop in compose.test.sh)
bash tests/compose.test.sh >"$work/compose.out" 2>&1 && ok "compose.test.sh (incl. tls-mount rules)" || { bad "compose.test.sh"; grep FAIL "$work/compose.out"; }
grep -q 'tls-init' "$work/compose.out" && ok "compose.test.sh checks tls-init" || bad "compose.test.sh checks tls-init"

echo; [[ $fails == 0 ]] && echo "pki.test.sh: all passed" || echo "pki.test.sh: $fails FAILED"
exit $((fails > 0))
