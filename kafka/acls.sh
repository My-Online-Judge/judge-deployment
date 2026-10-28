#!/bin/bash
# kafka-init (sub-project 10 §4.5): writes every service identity's Kafka ACLs through kafka:29092 as kafka-admin.
# A principal is the CN of the client's certificate (the broker's ssl.principal.mapping.rules). kafka, kafka-admin and
# ANONYMOUS (the loopback-only LOCAL listener) are super users and need no ACL. --add is idempotent, so this runs on every
# `up`; the ACLs persist in the KRaft metadata log on kafkadata. Deleting a rule here does not remove it from the broker.
set -euo pipefail
acls=(/opt/kafka/bin/kafka-acls.sh --bootstrap-server kafka:29092 --command-config /opt/oj/kafka/admin-client.properties)

# principal resource-type name operation — one rule per line (tests/kafka-acls.test.sh compares it with spec §4.5).
# The Run lane (Run code design §9): submission-service publishes run.requested and reads run.judged as run-results-<instance>
# (one group per instance, so each instance sees every reply and completes only its own runs; the old group run-results
# keeps its ACL on the broker, unused);
# run-worker (its own certificate) reads run.requested as run-workers and publishes run.judged — nothing of the submit lane.
# kafka-cluster is Kafka's fixed name for the cluster resource. * is Kafka's wildcard resource name (every topic or group): it
# is passed quoted below, never expanded by the shell. kafka-exporter (sp12 task 15) only describes: metadata, offsets, lag.
rules=$(cat <<'RULES'
User:submission-service Topic submission.requested Write
User:submission-service Topic submission.requested Describe
User:submission-service Topic submission.requested Create
User:submission-service Topic submission.requested Alter
User:submission-service Topic submission.requested DescribeConfigs
User:submission-service Topic oj.submission.events Write
User:submission-service Topic oj.submission.events Describe
User:submission-service Topic oj.submission.events Create
User:submission-service Topic oj.submission.events Alter
User:submission-service Topic oj.submission.events DescribeConfigs
User:submission-service Topic submission.judged.dlq Write
User:submission-service Topic submission.judged.dlq Describe
User:submission-service Topic submission.judged.dlq Create
User:submission-service Topic submission.judged.dlq Alter
User:submission-service Topic submission.judged.dlq DescribeConfigs
User:submission-service Topic submission.judged Read
User:submission-service Topic submission.judged Describe
User:submission-service Topic submission.judged Create
User:submission-service Topic submission.judged Alter
User:submission-service Topic submission.judged DescribeConfigs
User:submission-service Group judge-api-results Read
User:submission-service Cluster kafka-cluster Describe
User:problem-service Topic oj.submission.events Read
User:problem-service Topic oj.submission.events Describe
User:problem-service Topic oj.submission.events Create
User:problem-service Topic oj.submission.events Alter
User:problem-service Topic oj.submission.events DescribeConfigs
User:problem-service Topic oj.submission.events.dlq Write
User:problem-service Topic oj.submission.events.dlq Describe
User:problem-service Topic oj.submission.events.dlq Create
User:problem-service Topic oj.submission.events.dlq Alter
User:problem-service Topic oj.submission.events.dlq DescribeConfigs
User:problem-service Group problem-service-stats Read
User:problem-service Cluster kafka-cluster Describe
User:judge-worker Topic submission.requested Read
User:judge-worker Topic submission.requested Describe
User:judge-worker Topic submission.requested Create
User:judge-worker Topic submission.judged Write
User:judge-worker Topic submission.judged Describe
User:judge-worker Topic submission.judged Create
User:judge-worker Group judge-workers Read
User:judge-worker Topic submission.started Write
User:judge-worker Topic submission.started Describe
User:judge-worker Topic submission.started Create
User:submission-service Topic submission.started Read
User:submission-service Topic submission.started Describe
User:submission-service Topic submission.started Create
User:submission-service Topic submission.started Alter
User:submission-service Topic submission.started DescribeConfigs
User:submission-service Group submission-started Read
User:submission-service Topic run.requested Write
User:submission-service Topic run.requested Describe
User:submission-service Topic run.requested Create
User:submission-service Topic run.requested Alter
User:submission-service Topic run.requested DescribeConfigs
User:submission-service Topic run.judged Read
User:submission-service Topic run.judged Describe
User:submission-service Topic run.judged Create
User:submission-service Topic run.judged Alter
User:submission-service Topic run.judged DescribeConfigs
User:submission-service GroupPrefix run-results- Read
User:run-worker Topic run.requested Read
User:run-worker Topic run.requested Describe
User:run-worker Topic run.requested Create
User:run-worker Topic run.judged Write
User:run-worker Topic run.judged Describe
User:run-worker Topic run.judged Create
User:run-worker Group run-workers Read
User:kafka-exporter Topic * Describe
User:kafka-exporter Group * Describe
User:kafka-exporter Cluster kafka-cluster Describe
RULES
)

# One kafka-acls.sh run (one JVM) per principal and resource, with all of that pair's operations.
while read -r principal type name; do
  case $type in
    Topic) resource=(--topic "$name") ;;
    Group) resource=(--group "$name") ;;
    # A prefixed group: every submission-service instance reads run.judged in its own group run-results-<instance>.
    GroupPrefix) resource=(--group "$name" --resource-pattern-type prefixed) ;;
    Cluster) resource=(--cluster) ;;
    *) echo "acls.sh: unknown resource type '$type'" >&2; exit 1 ;;
  esac
  ops=$(awk -v p="$principal" -v t="$type" -v n="$name" '$1 == p && $2 == t && $3 == n { printf "%s ", $4 }' <<< "$rules")
  args=()
  for op in $ops; do args+=(--operation "$op"); done
  # kafka-acls.sh reports its errors on stdout: show its output only when it fails.
  if ! out=$("${acls[@]}" --add --allow-principal "$principal" "${resource[@]}" "${args[@]}" 2>&1); then
    echo "$out" >&2; echo "acls.sh: adding $principal $type $name failed" >&2; exit 1
  fi
  echo "acls.sh: $principal $type $name: $ops"
done < <(awk '!seen[$1 " " $2 " " $3]++ { print $1, $2, $3 }' <<< "$rules")

# What the broker now holds, one ACL per line: principal resource-type name operation permission host.
list=$("${acls[@]}" --list 2>&1) || { echo "$list" >&2; echo "acls.sh: --list failed" >&2; exit 1; }
echo "acls.sh: ACLs on the broker:"
awk '
  /resourceType=/ { type = $0; sub(/.*resourceType=/, "", type); sub(/,.*/, "", type)
                    name = $0; sub(/.*, name=/, "", name); sub(/, patternType=.*/, "", name) }
  /\(principal=/  { p = $0; sub(/.*principal=/, "", p); sub(/,.*/, "", p)
                    h = $0; sub(/.*host=/, "", h); sub(/,.*/, "", h)
                    op = $0; sub(/.*operation=/, "", op); sub(/,.*/, "", op)
                    perm = $0; sub(/.*permissionType=/, "", perm); sub(/\).*/, "", perm)
                    print p, type, name, op, perm, h }' <<< "$list" | sort
