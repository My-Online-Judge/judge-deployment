#!/usr/bin/env bash
# Copies the records of a dead-letter topic back to the topic they came from (SP11 §3.7).
#   scripts/replay-dlq.sh <dlq-topic> <target-topic> [--max N]
# Runs inside the Kafka container on its loopback LOCAL listener (127.0.0.1:9092: plaintext, the ANONYMOUS super user),
# so it needs no certificate. The consumer group dlq-replay commits its offsets: a second run copies only the records
# that no earlier run copied. Keys are kept (print.key / parse.key, tab-separated).
set -euo pipefail
usage() { echo "Usage: $0 <dlq-topic> <target-topic> [--max N]" >&2; exit 2; }
[[ $# -ge 2 ]] || usage
dlq=$1 target=$2; shift 2
max=
if [[ $# -gt 0 ]]; then
  [[ $1 == --max && $# -eq 2 && $2 =~ ^[1-9][0-9]*$ ]] || usage
  max=$2
fi
[[ $dlq != "$target" ]] || { echo "replay-dlq: the target topic must differ from the dead-letter topic" >&2; exit 2; }
[[ $dlq =~ ^[A-Za-z0-9._-]+$ && $target =~ ^[A-Za-z0-9._-]+$ ]] || { echo "replay-dlq: invalid topic name" >&2; exit 2; }

max_arg=${max:+--max-messages $max}
# The script is sent on stdin, so nothing is expanded by a second shell on the host side.
container=${KAFKA_CONTAINER:-oj-kafka}
# Verified on apache/kafka 3.8.1: with --group and --timeout-ms the consumer exits 0 after the timeout, with or without
# data (stderr then carries a TimeoutException and "Processed a total of N messages"), and commits the group's offsets.
# So its stderr is kept in a file and shown only when it exits non-zero. The producer with parse.key=true exits 1 on a
# line without the separator.
docker exec -i "$container" bash -s <<SCRIPT
set -euo pipefail
bin=/opt/kafka/bin
tab=\$'\t'
f=\$(mktemp); e=\$(mktemp); trap 'rm -f "\$f" "\$e"' EXIT
if ! \$bin/kafka-console-consumer.sh --bootstrap-server 127.0.0.1:9092 --topic $dlq --group dlq-replay \\
  --from-beginning --timeout-ms 10000 $max_arg \\
  --property print.key=true --property key.separator="\$tab" > "\$f" 2> "\$e"; then
  cat "\$e" >&2; echo "replay-dlq: reading $dlq failed" >&2; exit 1
fi
n=\$(wc -l < "\$f")
if [ "\$n" -gt 0 ]; then
  if ! \$bin/kafka-console-producer.sh --bootstrap-server 127.0.0.1:9092 --topic $target \\
    --property parse.key=true --property key.separator="\$tab" < "\$f" > /dev/null; then
    cat >&2 <<MSG
replay-dlq: writing to $target failed, but the dlq-replay offsets on $dlq were already committed.
To read the records again, reset them:
  docker exec $container /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --group dlq-replay --topic $dlq --reset-offsets --to-earliest --execute
Copying again is safe because the consumers are idempotent, except for the rejudge-ordering caveat in the README.
MSG
    exit 1
  fi
fi
echo "replayed \$n record(s) from $dlq to $target"
SCRIPT
