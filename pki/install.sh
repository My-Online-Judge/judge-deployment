#!/bin/sh
# Runs in the tls-init service: /pki (ro, pki/out) -> /tls (named volume), owner and modes per /identities.txt.
# The per-id directory is replaced, so a re-issued leaf never leaves a stale file behind.
set -eu
rc=0
while read -r id owner _; do
  case "$id" in ''|'#'*) continue ;; esac
  if [ ! -d "/pki/$id" ]; then
    [ "$id" = rogue ] && continue
    echo "tls-init: no certificate directory for $id (run pki/pki.sh issue-all)" >&2
    rc=1
    continue
  fi
  rm -rf "/tls/$id"
  cp -R "/pki/$id" "/tls/$id"
  chown -R "$owner" "/tls/$id"
  find "/tls/$id" -type d -exec chmod 0700 {} +
  find "/tls/$id" -type f -exec chmod 0644 {} +
  find "/tls/$id" -type f \( -name '*.key' -o -name keystore.pem \) -exec chmod 0600 {} +
  echo "tls-init: installed $id"
done < /identities.txt
chmod 0755 /tls
exit $rc
