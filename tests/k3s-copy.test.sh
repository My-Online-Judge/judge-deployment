#!/usr/bin/env bash
# k3s/scripts/copy-from-compose.sh (the cutover's data copy): one script copies all three databases and the test-case bucket from the
# compose stack into K3s, with the K3s services stopped for the copy and started after it, so the same command serves the rehearsal and
# the final copy and nothing written on compose between two steps of a hand-run list can be forgotten. --dry-run prints the plan
# without touching docker or kubectl. Prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
s=k3s/scripts/copy-from-compose.sh
[[ -x $s ]] || { bad "$s exists and is executable"; exit 1; }
out=$(bash "$s" --dry-run 2>&1) || { bad "--dry-run succeeds: $out"; exit 1; }
n() { grep -n -m1 -- "$1" <<< "$out" | cut -d: -f1 || true; }
down=$(n "scale .*--replicas=0"); up=$(n "scale .*--replicas=1")
[[ -n $down && -n $up && $down -lt $up ]] && ok "the K3s services are scaled down first and up last" || bad "scale down/up order ($down, $up)"
for svc in identity problem submission; do
  d=$(n "pg_dump.*oj-$svc-db"); [[ -n $d ]] || d=$(n "oj-$svc-db.*pg_dump")
  r=$(n "pg_restore.*$svc-db-0"); [[ -n $r ]] || r=$(n "$svc-db-0.*pg_restore")
  [[ -n $d && -n $r && $d -gt $down && $r -lt $up ]] && ok "$svc-db is dumped from compose and restored into K3s between the scale-down and the scale-up" || bad "$svc-db copy ($d, $r, down=$down, up=$up)"
done
m=$(n "mc.*mirror.*--remove"); [[ -n $m && $m -gt $down && $m -lt $up ]] && ok "the bucket is mirrored exactly (--remove) between them" || bad "bucket mirror ($m)"
[[ $(grep -c "pg_restore" <<< "$out") -ge 3 && $(grep -c -- "--exit-on-error" <<< "$out") -ge 3 ]] && ok "every restore stops at its first error" || bad "restores use --exit-on-error"
grep -q "MC_HOST_k3s=" <<< "$out" && bad "the dry run printed a MinIO credential variable with a value" || ok "no MinIO credential is printed or put on a command line"
grep -q -- "--insecure" <<< "$out" && bad "the plan uses --insecure (only OJ_COPY_INSECURE=1 on macOS may)" || ok "the plan verifies MinIO's certificate (no --insecure)"
exit $fail
