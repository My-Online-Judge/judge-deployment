#!/usr/bin/env bash
# Private CA and per-identity leaf certificates (sub-project 10 §4.2).
#   pki.sh init-ca [--force] | issue <id> [extra-san...] | issue-all | rogue | status | fixtures <dir>
# Output goes under PKI_OUT (default pki/out, gitignored): dirs 0700, keys 0600, certs 0644.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${PKI_OUT:-$here/out}
ca_days=3650 leaf_days=365 fixture_days=3650
umask 077

die() { echo "pki.sh: $*" >&2; exit 1; }

# san_list <id> [extra...] -> "DNS:id,DNS:localhost,IP:127.0.0.1,..." without duplicates
san_list() {
  local -a sans=("DNS:$1" "DNS:localhost" "IP:127.0.0.1") ; local e s dup
  shift
  for e in "$@"; do
    if [[ $e =~ ^[0-9.]+$ || $e == *:* ]]; then e="IP:$e"; else e="DNS:$e"; fi
    dup=0; for s in "${sans[@]}"; do [[ $s == "$e" ]] && dup=1; done
    [[ $dup == 1 ]] || sans+=("$e")
  done
  local IFS=,; echo "${sans[*]}"
}

# new_ca <crt> <key> <cn>
new_ca() {
  openssl req -x509 -newkey rsa:2048 -nodes -days "$ca_days" -subj "/CN=$3" \
    -addext "basicConstraints=critical,CA:true,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$2.tmp" -out "$1" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$2.tmp" -out "$2" && rm -f "$2.tmp"
  chmod 600 "$2"; chmod 644 "$1"
}

# new_leaf <ca.crt> <ca.key> <cn> <crt> <key> <days> <san-list>
new_leaf() {
  local tmp; tmp=$(mktemp -d)
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$3" -keyout "$tmp/k" -out "$tmp/csr" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$tmp/k" -out "$5"
  cat > "$tmp/ext" <<EXT
subjectAltName=$7
extendedKeyUsage=serverAuth,clientAuth
keyUsage=critical,digitalSignature,keyEncipherment
basicConstraints=CA:false
EXT
  openssl x509 -req -in "$tmp/csr" -CA "$1" -CAkey "$2" -set_serial "0x$(openssl rand -hex 16)" \
    -days "$6" -extfile "$tmp/ext" -out "$4" 2>/dev/null
  rm -rf "$tmp"
  chmod 600 "$5"; chmod 644 "$4"
}

need_ca() { [[ -f $out/ca/ca.crt && -f $out/ca/ca.key ]] || die "no CA under $out/ca (run init-ca)"; }

cmd_init_ca() {
  local force=0; [[ ${1:-} == --force ]] && force=1
  if [[ -e $out/ca/ca.key && $force == 0 ]]; then die "CA already exists in $out/ca (use --force to replace it)"; fi
  mkdir -p "$out/ca"; chmod 700 "$out" "$out/ca"
  new_ca "$out/ca/ca.crt" "$out/ca/ca.key" "My-OJ Internal Root CA"
  echo "CA written to $out/ca"
}

cmd_issue() {
  local id=${1:?usage: issue <id> [extra-san...]}; shift
  need_ca
  local d=$out/$id; rm -rf "$d"; mkdir -p "$d"; chmod 700 "$out" "$d"
  new_leaf "$out/ca/ca.crt" "$out/ca/ca.key" "$id" "$d/tls.crt" "$d/tls.key" "$leaf_days" "$(san_list "$id" "$@")"
  cp "$out/ca/ca.crt" "$d/ca.crt"; chmod 644 "$d/ca.crt"
  cat "$d/tls.key" "$d/tls.crt" > "$d/keystore.pem"; chmod 600 "$d/keystore.pem"
  if [[ $id == minio ]]; then
    mkdir -p "$d/CAs"; chmod 700 "$d/CAs"
    cp "$d/tls.crt" "$d/public.crt"; cp "$d/tls.key" "$d/private.key"; cp "$out/ca/ca.crt" "$d/CAs/ca.crt"
    chmod 644 "$d/public.crt" "$d/CAs/ca.crt"; chmod 600 "$d/private.key"
  fi
}

cmd_issue_all() {
  local id uid extra host=${OJ_PUBLIC_HOST:-localhost} x
  while read -r id uid extra; do
    case "$id" in ''|'#'*|rogue) continue ;; esac
    local -a sans=()
    for x in $extra; do sans+=("${x//\$\{OJ_PUBLIC_HOST\}/$host}"); done
    cmd_issue "$id" "${sans[@]}"
    echo "issued $id"
  done < "$here/identities.txt"
}

cmd_rogue() {
  need_ca
  local d=$out/rogue; rm -rf "$d"; mkdir -p "$d"; chmod 700 "$out" "$d"
  new_ca "$d/rogue-ca.crt" "$d/rogue-ca.key" "Rogue CA"
  new_leaf "$d/rogue-ca.crt" "$d/rogue-ca.key" "tls-probe" "$d/tls.crt" "$d/tls.key" "$leaf_days" "$(san_list tls-probe)"
  cp "$out/ca/ca.crt" "$d/ca.crt"   # trust anchor for the server side of a probe; the client cert is the rogue one
}

cmd_status() {
  local id crt end now days
  now=$(date +%s)
  while read -r id _; do
    case "$id" in ''|'#'*) continue ;; esac
    crt=$out/$id/tls.crt
    [[ -f $crt ]] || { echo "$id missing -"; continue; }
    end=$(date -d "$(openssl x509 -enddate -noout -in "$crt" | cut -d= -f2)" +%s)
    days=$(( (end - now) / 86400 ))
    echo "$id $days $(openssl x509 -serial -noout -in "$crt" | cut -d= -f2)"
  done < "$here/identities.txt"
}

cmd_fixtures() {
  local dir=${1:?usage: fixtures <dir>} t; mkdir -p "$dir"
  new_ca "$dir/ca.crt" "$dir/ca.key" "My-OJ Test CA"
  leaf() { new_leaf "$dir/ca.crt" "$dir/ca.key" "$1" "$dir/$2.crt" "$dir/$2.key" "$fixture_days" "$(san_list "$1")"; }
  leaf localhost server
  for t in api-gateway submission-service edge tls-probe; do leaf "$t" "$t"; done
  new_ca "$dir/rogue-ca.crt" "$dir/rogue-ca.key" "Test Rogue CA"
  new_leaf "$dir/rogue-ca.crt" "$dir/rogue-ca.key" tls-probe "$dir/rogue-client.crt" "$dir/rogue-client.key" "$fixture_days" "$(san_list tls-probe)"
  rm -f "$dir/ca.key" "$dir/rogue-ca.key"   # test fixtures never need to sign anything again
  chmod 644 "$dir"/*.crt
}

case "${1:-}" in
  init-ca) shift; cmd_init_ca "$@" ;;
  issue) shift; cmd_issue "$@" ;;
  issue-all) cmd_issue_all ;;
  rogue) cmd_rogue ;;
  status) cmd_status ;;
  fixtures) shift; cmd_fixtures "$@" ;;
  *) die "usage: pki.sh init-ca [--force] | issue <id> [san...] | issue-all | rogue | status | fixtures <dir>" ;;
esac
