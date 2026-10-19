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
docker exec -i "${KAFKA_CONTAINER:-oj-kafka}" bash -s <<SCRIPT
set -euo pipefail
bin=/opt/kafka/bin
tab=\$'\t'
f=\$(mktemp); trap 'rm -f "\$f"' EXIT
\$bin/kafka-console-consumer.sh --bootstrap-server 127.0.0.1:9092 --topic $dlq --group dlq-replay \\
  --from-beginning --timeout-ms 10000 $max_arg \\
  --property print.key=true --property key.separator="\$tab" 2>/dev/null > "\$f"
n=\$(wc -l < "\$f")
if [ "\$n" -gt 0 ]; then
  \$bin/kafka-console-producer.sh --bootstrap-server 127.0.0.1:9092 --topic $target \\
    --property parse.key=true --property key.separator="\$tab" < "\$f" > /dev/null
fi
echo "replayed \$n record(s) from $dlq to $target"
SCRIPT
