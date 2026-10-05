#!/usr/bin/env bash
# The drain waits until the judge queue is empty AND the judge-workers group has consumed submission.requested, twice
# in a row — the reconcile job can zero the queue rows while the worker still holds stale messages (review C1) — and
# gives up at its limit (Review Focus 4). curl and docker are stubs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
stub=$(mktemp -d); trap 'rm -rf "$stub"' EXIT
cat > "$stub/curl" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_COUNT"
v=${STUB_DEPTH:-0}; [ -n "${STUB_EMPTY_AFTER:-}" ] && [ "$n" -ge "$STUB_EMPTY_AFTER" ] && v=0
echo "{\"data\":{\"result\":[{\"metric\":{},\"value\":[1,\"$v\"]}]}}"
EOF
cat > "$stub/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = exec ] || exit 0
[ -n "${STUB_NO_KAFKA:-}" ] && exit 1
lag=${STUB_LAG:-0}
echo
echo "GROUP         TOPIC                PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID  HOST  CLIENT-ID"
echo "judge-workers submission.requested 0          10              10              0    c1           /1.2  kafka-python"
echo "judge-workers submission.requested 1          7               $((7 + lag))    $lag c1           /1.2  kafka-python"
echo "judge-workers submission.requested 2          -               0               -    c1           /1.2  kafka-python"
EOF
chmod +x "$stub/curl" "$stub/docker"
fail=0
drain() { (export PATH="$stub:$PATH" STUB_COUNT="$stub/count" DRAIN_POLL_S=0.1; rm -f "$stub/count"; source "$here/../lib/common.sh"; source "$here/../lib/drain.sh"; drain_queue "$1"); }
check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (got '$1')"; fail=1; fi; }
check "$(STUB_DEPTH=0 drain 5)" empty "an empty queue with nothing unconsumed drains at once"
check "$(STUB_DEPTH=4 STUB_EMPTY_AFTER=3 drain 5)" empty "a queue that empties later drains"
check "$(STUB_DEPTH=4 drain 1)" timeout "a queue that never empties times out"
check "$(STUB_DEPTH=0 STUB_LAG=5 drain 1)" timeout "an empty queue with messages still unconsumed is not drained (review C1)"
check "$(STUB_DEPTH=0 STUB_NO_KAFKA=1 drain 1)" timeout "no answer from Kafka is not taken as drained"
exit $fail
