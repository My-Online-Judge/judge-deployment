#!/usr/bin/env bash
# pki/pki.sh, pki/install.sh and the compose tls-mount rules (sub-project 10, task 1). Needs host openssl and docker.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
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

# root CA properties
ca=$PKI_OUT/ca/ca.crt; ct=$(openssl x509 -in "$ca" -noout -text 2>/dev/null)
has "CA:TRUE" "$ct" && has "pathlen:0" "$ct" && has "Certificate Sign, CRL Sign" "$ct" && has "CN *= *My-OJ Internal Root CA" "$ct" && ok "root: CA:TRUE pathlen:0, keyCertSign+cRLSign, CN" || bad "root: CA:TRUE pathlen:0, keyCertSign+cRLSign, CN"
openssl x509 -in "$ca" -noout -checkend $((3649 * 86400)) >/dev/null && ! openssl x509 -in "$ca" -noout -checkend $((3651 * 86400)) >/dev/null && ok "root valid ~10 years" || bad "root valid ~10 years"
[[ $(stat -c %a "$PKI_OUT/ca/ca.key") == 600 && $(stat -c %a "$PKI_OUT/ca") == 700 && $(stat -c %a "$PKI_OUT") == 700 ]] && ok "CA key 600, ca dir 700, out dir 700" || bad "CA key 600, ca dir 700, out dir 700"
has "Digital Signature, Key Encipherment" "$text" && has "CA:FALSE" "$text" && ok "leaf keyUsage and CA:FALSE" || bad "leaf keyUsage and CA:FALSE"
openssl x509 -in "$foo/tls.crt" -noout -checkend $((364 * 86400)) >/dev/null && ! openssl x509 -in "$foo/tls.crt" -noout -checkend $((366 * 86400)) >/dev/null && ok "leaf valid 365 days" || bad "leaf valid 365 days"
# ids that could destroy the CA or escape the output dir are refused, the CA stays intact
cahash=$(sha256sum "$PKI_OUT/ca/ca.key" "$ca" | sha256sum)
for badid in ca / ../x Foo -x 'a b'; do
  "$pki" issue "$badid" >/dev/null 2>&1 && bad "issue '$badid' refused" || ok "issue '$badid' refused"
done
[[ $(sha256sum "$PKI_OUT/ca/ca.key" "$ca" | sha256sum) == "$cahash" ]] && ok "CA intact after refused ids" || bad "CA intact after refused ids"
"$pki" issue bad-san host:8080 >/dev/null 2>&1 && bad "SAN host:port refused" || ok "SAN host:port refused"
"$pki" issue localhost >/dev/null 2>&1; [[ $(openssl x509 -in "$PKI_OUT/localhost/tls.crt" -noout -text | grep -o 'DNS:localhost' | wc -l) == 1 ]] && ok "no duplicate DNS:localhost" || bad "no duplicate DNS:localhost"

"$pki" rogue >/dev/null 2>&1
[[ $(stat -c %a "$PKI_OUT/rogue/ca.crt") == 644 ]] && ok "rogue/ca.crt is 644" || bad "rogue/ca.crt is 644"
if openssl verify -CAfile "$PKI_OUT/ca/ca.crt" "$PKI_OUT/rogue/tls.crt" >/dev/null 2>&1; then bad "rogue leaf fails against our CA"; else ok "rogue leaf fails against our CA"; fi
has "CN *= *tls-probe" "$(openssl x509 -in "$PKI_OUT/rogue/tls.crt" -noout -subject)" && ok "rogue CN is tls-probe" || bad "rogue CN is tls-probe"
"$pki" init-ca >/dev/null 2>&1; [[ $? == 1 ]] && ok "init-ca refuses to overwrite" || bad "init-ca refuses to overwrite"
before=$(openssl x509 -in "$PKI_OUT/ca/ca.crt" -noout -serial)
"$pki" init-ca --force >/dev/null 2>&1; ls "$PKI_OUT"/ca/ca.key.bak-* >/dev/null 2>&1 && ok "init-ca --force keeps the old key" || bad "init-ca --force keeps the old key"
[[ $(openssl x509 -in "$PKI_OUT/ca/ca.crt" -noout -serial) != "$before" ]] && ok "init-ca --force replaces" || bad "init-ca --force replaces"

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
[[ $(st '%u:%g %a' api-gateway) == "10001:10001 700" ]] && ok "api-gateway dir 10001:10001 700" || bad "api-gateway dir 10001:10001 700"
# sp12 task 13: the application containers run as uid 10001 (portal: nginx 101) and read their own key
[[ $(st '%u:%g %a' identity-service/tls.key) == "10001:10001 600" ]] && ok "identity-service key 10001:10001 600" || bad "identity-service key 10001:10001 600"
[[ $(st '%u:%g %a' judge-portal/tls.key) == "101:101 600" ]] && ok "judge-portal key 101:101 600" || bad "judge-portal key 101:101 600"
[[ $(st '%a' api-gateway/tls.crt) == 644 && $(st '%a' kafka/keystore.pem) == 600 && $(st '%a' minio/private.key) == 600 && $(st '%a' minio/CAs) == 700 ]] && ok "cert 644, keystore.pem 600, private.key 600, nested dir 700" || bad "modes of cert, keystore.pem, private.key, nested dir"
# The sandboxes compile and run submitted code as users 12001-12003 (compiler, code, spj) while gunicorn, root, reads the
# key: their identities stay root's, the directory 0700 and every file but the certificates 0600 (task 12 checked through
# the judger that a submission then cannot read the key).
for js in judge-server judge-server-2; do
  owner=$(awk -v id="$js" '$1 == id {print $2}' pki/identities.txt)
  modes=$(docker --context default run --rm -v "$tlsdir:/tls:ro" alpine:3.22 sh -c "cd /tls/$js && stat -c '%n %u:%g %a' . *" 2>/dev/null)
  if [[ $owner == 0:0 ]] && grep -qx '\. 0:0 700' <<< "$modes" && grep -qx 'tls\.key 0:0 600' <<< "$modes" \
    && awk '$1 != "." { if ($1 ~ /\.crt$/) { if ($2 != "0:0" || $3 != "644") wrong = 1 } else if ($2 != "0:0" || $3 != "600") wrong = 1 } END { exit wrong }' <<< "$modes"; then
    ok "$js: listed 0:0; dir 0:0 700, key and every other non-.crt file 0:0 600"
  else bad "$js: listed 0:0; dir 0:0 700, key and every other non-.crt file 0:0 600 (identities.txt: '$owner'; installed: $(tr '\n' ';' <<< "$modes"))"; fi
done

# rotation: re-issue (same CA), reinstall, no stale file
"$pki" issue redis >/dev/null 2>&1
docker --context default run --rm -v "$tlsdir:/tls" alpine:3.22 touch /tls/redis/stale >/dev/null 2>&1
install_run >/dev/null 2>&1
new=$(openssl x509 -in "$PKI_OUT/redis/tls.crt" -noout -serial)
inst=$(docker --context default run --rm -v "$tlsdir:/tls:ro" alpine:3.22 cat /tls/redis/tls.crt | openssl x509 -noout -serial)
[[ $new == "$inst" ]] && ok "re-issued leaf is what is installed" || bad "re-issued leaf is what is installed"
[[ -z $(docker --context default run --rm -v "$tlsdir:/tls:ro" alpine:3.22 ls /tls/redis | grep stale) ]] && ok "no stale file after re-install" || bad "no stale file after re-install"
# a container already running with the identity directory mounted (as volume.subpath does) must see a re-install
holder=$(docker --context default run -d --rm -v "$tlsdir/redis:/t:ro" alpine:3.22 sleep 120 2>/dev/null)
docker --context default run --rm -v "$tlsdir:/tls" alpine:3.22 touch /tls/redis/gone >/dev/null 2>&1
"$pki" issue redis >/dev/null 2>&1
install_run >/dev/null 2>&1
new=$(openssl x509 -in "$PKI_OUT/redis/tls.crt" -noout -serial)
seen=$(docker --context default exec "$holder" cat /t/tls.crt 2>/dev/null | openssl x509 -noout -serial 2>/dev/null)
[[ -n $seen && $new == "$seen" ]] && ok "a running container mounting the directory reads the re-installed leaf" || bad "a running container mounting the directory reads the re-installed leaf"
docker --context default exec "$holder" ls /t 2>/dev/null | grep -qx gone && bad "a file removed from the source disappears" || ok "a file removed from the source disappears"
docker --context default exec "$holder" ls /t 2>/dev/null | grep -q tmp-install && bad "no temp file is left behind" || ok "no temp file is left behind"
docker --context default rm -f "$holder" >/dev/null 2>&1
rm -rf "$PKI_OUT/problem-db"
install_run >/dev/null 2>&1; [[ $? != 0 ]] && ok "install.sh fails when a listed id has no source" || bad "install.sh fails when a listed id has no source"
printf 'ca 0:0\n' > "$work/badids"
docker --context default run --rm -v "$PKI_OUT:/pki:ro" -v "$PWD/pki/install.sh:/install.sh:ro" -v "$work/badids:/identities.txt:ro" -v "$tlsdir:/tls" --entrypoint /bin/sh alpine:3.22 /install.sh >/dev/null 2>&1; [[ $? != 0 ]] && ok "install.sh refuses id 'ca'" || bad "install.sh refuses id 'ca'"
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
