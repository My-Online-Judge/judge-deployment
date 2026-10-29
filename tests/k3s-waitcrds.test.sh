#!/usr/bin/env bash
# k3s/scripts/wait-for-crds.sh: right after `kubectl apply -k k3s/platform` the CRDs of cert-manager and KEDA do not exist yet (K3s's Helm
# controller installs the charts a minute later), and `kubectl wait` on a missing object fails at once instead of waiting. The script waits
# for each CRD to exist, then to be established, and gives up with a message after its timeout. A stub kubectl stands in for the cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
s=k3s/scripts/wait-for-crds.sh
[[ -x $s ]] || { bad "$s exists and is executable"; exit 1; }
mkdir "$tmp/bin"
# the stub: `get crd X` fails for the first $MISSING_FOR calls, then succeeds; `wait` always succeeds; every call is logged
cat > "$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case $1 in
  get) n=$(cat "$STUB_COUNT" 2> /dev/null || echo 0); echo $((n + 1)) > "$STUB_COUNT"; (( n >= ${MISSING_FOR:-0} )) || { echo "Error from server (NotFound)" >&2; exit 1; } ;;
  wait) ;;
esac
STUB
chmod +x "$tmp/bin/kubectl"
export STUB_LOG=$tmp/log STUB_COUNT=$tmp/count WAIT_INTERVAL=0.1 PATH="$tmp/bin:$PATH"

: > "$STUB_LOG"; rm -f "$STUB_COUNT"
MISSING_FOR=3 bash "$s" 5 crd/a.example.com crd/b.example.com > "$tmp/out" 2>&1 && ok "it waits through a missing CRD and succeeds once it exists" || bad "missing then present: $(cat "$tmp/out")"
[[ $(grep -c '^wait' "$STUB_LOG") == 2 ]] && ok "then waits for each CRD to be established" || bad "wait calls: $(grep -c '^wait' "$STUB_LOG")"
first_wait=$(grep -n '^wait' "$STUB_LOG" | head -1 | cut -d: -f1); gets_before=$(head -n $((first_wait - 1)) "$STUB_LOG" | grep -c '^get')
(( gets_before >= 4 )) && ok "no kubectl wait before the CRD exists (it asked $gets_before times)" || bad "wait came too early ($gets_before gets before it)"

: > "$STUB_LOG"; rm -f "$STUB_COUNT"
if MISSING_FOR=100000 bash "$s" 1 crd/never.example.com > "$tmp/out" 2>&1; then bad "a CRD that never appears must fail"; else
  grep -q "never.example.com" "$tmp/out" && ok "a CRD that never appears fails after the timeout, naming it" || bad "the failure does not name the CRD: $(cat "$tmp/out")"
fi
exit $fail
