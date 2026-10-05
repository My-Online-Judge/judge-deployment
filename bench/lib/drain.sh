# drain_queue <max_s> — waits until the judge queue (max(oj_queue_depth) on the bench Prometheus) reads 0 twice in
# a row; prints "empty", or "timeout" after max_s. Sourced after common.sh.
drain_queue() {
  local max_s=$1 zeros=0 v deadline=$((SECONDS + $1))
  while :; do
    v=$(curl -s --get "$PROM_URL/api/v1/query" --data-urlencode 'query=max(oj_queue_depth)' | jq -r '.data.result[0].value[1] // "none"')
    if [ "$v" = 0 ]; then zeros=$((zeros + 1)); else zeros=0; fi
    if [ $zeros -ge 2 ]; then echo empty; return 0; fi
    if [ $SECONDS -ge $deadline ]; then echo timeout; return 0; fi
    sleep "${DRAIN_POLL_S:-5}"
  done
}
