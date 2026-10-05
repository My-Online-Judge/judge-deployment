#!/usr/bin/env bash
# The drain waits for two empty readings of the judge queue, and gives up at its limit (Review Focus 4).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
stub=$(mktemp -d); trap 'rm -rf "$stub"' EXIT
cat > "$stub/curl" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_COUNT"
v=${STUB_DEPTH:-0}; [ -n "${STUB_EMPTY_AFTER:-}" ] && [ "$n" -ge "$STUB_EMPTY_AFTER" ] && v=0
echo "{\"data\":{\"result\":[{\"metric\":{},\"value\":[1,\"$v\"]}]}}"
EOF
chmod +x "$stub/curl"
fail=0
drain() { (export PATH="$stub:$PATH" STUB_COUNT="$stub/count" DRAIN_POLL_S=0.1; rm -f "$stub/count"; source "$here/../lib/common.sh"; source "$here/../lib/drain.sh"; drain_queue "$1"); }
if [ "$(STUB_DEPTH=0 drain 5)" = empty ]; then echo "ok   an empty queue drains at once"; else echo "FAIL an empty queue drains at once"; fail=1; fi
if [ "$(STUB_DEPTH=4 STUB_EMPTY_AFTER=3 drain 5)" = empty ]; then echo "ok   a queue that empties later drains"; else echo "FAIL a queue that empties later drains"; fail=1; fi
if [ "$(STUB_DEPTH=4 drain 1)" = timeout ]; then echo "ok   a queue that never empties times out"; else echo "FAIL a queue that never empties times out"; fail=1; fi
exit $fail
