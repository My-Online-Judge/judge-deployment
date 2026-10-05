# drain_queue <max_s> — waits until the run's work is really done, twice in a row (5 s apart): the judge queue
# (max(oj_queue_depth) on the bench Prometheus) reads 0 AND the judge-workers group has consumed every
# submission.requested message. The queue alone is not enough: the reconcile job flips a submission queued > 5 min
# to SYSTEM_ERROR, zeroing the queue while the worker still holds its message (review C1). Prints "empty", or
# "timeout" after max_s. Sourced after common.sh.

# worker_lag — unconsumed submission.requested messages of the judge-workers group (read-only, inside the bench
# Kafka); "unknown" when Kafka gives no answer. A partition without a committed offset counts only if it holds data.
worker_lag() {
  docker exec oj-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe \
    --group judge-workers 2>/dev/null \
    | awk '$2 == "submission.requested" { seen = 1; if ($6 == "-") { if ($5 != "-" && $5 != 0) lag += 1000000 } else lag += $6 }
           END { if (seen) print lag + 0; else print "unknown" }'
}

drain_queue() {
  local zeros=0 v lag deadline=$((SECONDS + $1))
  while :; do
    v=$(curl -s --get "$PROM_URL/api/v1/query" --data-urlencode 'query=max(oj_queue_depth)' | jq -r '.data.result[0].value[1] // "none"')
    lag=$(worker_lag)
    if [ "$v" = 0 ] && [ "$lag" = 0 ]; then zeros=$((zeros + 1)); else zeros=0; fi
    if [ $zeros -ge 2 ]; then echo empty; return 0; fi
    if [ $SECONDS -ge $deadline ]; then echo timeout; return 0; fi
    sleep "${DRAIN_POLL_S:-5}"
  done
}
