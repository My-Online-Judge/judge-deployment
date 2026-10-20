#!/usr/bin/env bash
# scripts/replay-dlq.sh: argument checks and the script it sends into the Kafka container. A stub `docker` on PATH
# records its arguments and stdin; nothing touches a real broker.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/args"
cat > "$STUB_DIR/stdin" || true
echo "stub-docker-ran" >> "$STUB_DIR/calls"
STUB
chmod +x "$tmp/docker"
run() { STUB_DIR=$tmp PATH="$tmp:$PATH" bash scripts/replay-dlq.sh "$@" 2>&1; }
rm -f "$tmp/calls"

rc=0; out=$(run) || rc=$?
if [[ $rc -eq 2 && $out == *Usage* ]]; then ok "no arguments: usage error, exit 2"; else bad "no arguments: usage error, exit 2 (rc=$rc)"; fi
rc=0; out=$(run only-one) || rc=$?
if [[ $rc -eq 2 ]]; then ok "one argument: exit 2"; else bad "one argument: exit 2 (rc=$rc)"; fi
rc=0; out=$(run a a) || rc=$?
if [[ $rc -eq 2 && $out == *"must differ"* ]] && [[ ! -e $tmp/calls ]]; then ok "same dlq and target: refused before docker"; else bad "same dlq and target: refused before docker (rc=$rc)"; fi
rc=0; out=$(run a b --max) || rc=$?
if [[ $rc -eq 2 ]]; then ok "--max without a number: exit 2"; else bad "--max without a number: exit 2 (rc=$rc)"; fi
rc=0; out=$(run a b --max x) || rc=$?
if [[ $rc -eq 2 ]]; then ok "--max not a number: exit 2"; else bad "--max not a number: exit 2 (rc=$rc)"; fi

rc=0; out=$(run submission.judged.dlq submission.judged --max 5) || rc=$?
script=$(cat "$tmp/stdin" 2>/dev/null || true); args=$(cat "$tmp/args" 2>/dev/null || true)
[[ $args == "--context default exec -i oj-kafka bash"* ]] && ok "runs docker --context default exec -i oj-kafka bash" || bad "runs docker --context default exec -i oj-kafka bash (got: $args)"
for want in "--bootstrap-server 127.0.0.1:9092" "--group dlq-replay" "print.key=true" "parse.key=true" "--max-messages 5" \
  "--topic submission.judged.dlq" "--topic submission.judged " "--from-beginning" "--timeout-ms 10000"; do
  all="$args
$script"
  if [[ $all == *"$want"* ]]; then ok "script contains: $want"; else bad "script contains: $want"; fi
done
rm -f "$tmp/args" "$tmp/stdin"
run a b >/dev/null || true
all="$(cat "$tmp/args")
$(cat "$tmp/stdin")"
[[ $all != *"--max-messages"* ]] && ok "no --max: no --max-messages" || bad "no --max: no --max-messages"
rm -f "$tmp/args" "$tmp/stdin"; KAFKA_CONTAINER=other-kafka run a b >/dev/null || true
[[ $(cat "$tmp/args") == *"other-kafka"* ]] && ok "KAFKA_CONTAINER overrides the container" || bad "KAFKA_CONTAINER overrides the container"

# A produce failure inside the container: the stub runs the sent script against fake kafka tools (consumer prints one
# record, producer fails) and the script must exit non-zero and print the offset-reset recovery.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nprintf "k\\tv\\n"\n' > "$tmp/bin/kafka-console-consumer.sh"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/kafka-console-producer.sh"
chmod +x "$tmp/bin"/*
cat > "$tmp/docker-fail" <<'STUB'
#!/usr/bin/env bash
sed "s#/opt/kafka/bin#$STUB_DIR/bin#g" | bash -s
STUB
chmod +x "$tmp/docker-fail"; mkdir -p "$tmp/failpath"; cp "$tmp/docker-fail" "$tmp/failpath/docker"
rc=0; out=$(STUB_DIR=$tmp PATH="$tmp/failpath:$PATH" bash scripts/replay-dlq.sh a b 2>&1) || rc=$?
if [[ $rc -ne 0 && $out == *"--reset-offsets --to-earliest"* && $out == *"--topic a "* ]]; then ok "produce failure: non-zero exit and the offset-reset recovery"
else bad "produce failure: non-zero exit and the offset-reset recovery (rc=$rc)"; fi
exit $fail
