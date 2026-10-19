#!/bin/sh
# Runs in the tls-init service: /pki (ro, pki/out) -> /tls (named volume), owner and modes per /identities.txt.
# The per-id directory is updated in place (same inode, see below); files the source no longer has are removed.
set -eu
rc=0
while read -r id owner _; do
  case "$id" in ''|'#'*) continue ;; esac
  case "$id" in ca|-*|*[!a-z0-9-]*) echo "tls-init: refusing invalid identity '$id'" >&2; exit 1 ;; esac
  if [ ! -d "/pki/$id" ]; then
    [ "$id" = rogue ] && continue
    echo "tls-init: no certificate directory for $id (run pki/pki.sh issue-all)" >&2
    rc=1
    continue
  fi
  # Update in place and keep the directory itself: a running container mounts it with volume.subpath, and a replaced
  # directory would show that container an empty /etc/oj/tls. Each file is written under a temp name and renamed over
  # the final one (atomic for readers); files no longer in the source are deleted afterwards.
  mkdir -p "/tls/$id"
  chown "$owner" "/tls/$id"
  chmod 0700 "/tls/$id"
  want=$(mktemp)
  (cd "/pki/$id" && find . -mindepth 1 -type d) | while read -r d; do
    mkdir -p "/tls/$id/$d"; chown "$owner" "/tls/$id/$d"; chmod 0700 "/tls/$id/$d"
  done
  (cd "/pki/$id" && find . -type f) > "$want"
  while read -r f; do
    tmp="/tls/$id/$f.tmp-install"
    cp "/pki/$id/$f" "$tmp"
    chown "$owner" "$tmp"
    case "$f" in *.crt) chmod 0644 "$tmp" ;; *) chmod 0600 "$tmp" ;; esac
    mv -f "$tmp" "/tls/$id/$f"
  done < "$want"
  (cd "/tls/$id" && find . -type f) | while read -r f; do
    grep -qxF "$f" "$want" || rm -f "/tls/$id/$f"
  done
  rm -f "$want"
  echo "tls-init: installed $id"
done < /identities.txt
chmod 0755 /tls
exit $rc
