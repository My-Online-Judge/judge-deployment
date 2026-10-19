#!/usr/bin/env bash
# Kafka ACLs by certificate identity (sub-project 10 §4.5): kafka/acls.sh's rule table is exactly the spec's, and compose
# wires the authorizer, the leaf-CN principal mapping and the one-shot kafka-init. Prints descriptions, never a value.
# Run from anywhere — needs the gitignored .env* files beside docker-compose.yml (as tests/compose.test.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# Spec §4.5, one rule per line: principal resource-type name operation. kafka, kafka-admin and ANONYMOUS are super users.
expected='User:submission-service Topic submission.requested Write
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
User:submission-service Group submission-started Read'

# The table is the here-doc between <<'RULES' and RULES in acls.sh; comment and blank lines are not rules.
actual=$(sed -n "/<<'RULES'/,/^RULES\$/{/<<'RULES'/d;/^RULES\$/d;p}" kafka/acls.sh 2>/dev/null | sed 's/#.*//;s/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//' | grep -v '^$' || true)
if diff=$(diff <(echo "$expected") <(echo "$actual")); then
  ok "kafka/acls.sh applies exactly the spec §4.5 table ($(wc -l <<< "$expected") rules)"
else
  bad "kafka/acls.sh's table differs from spec §4.5 (< spec, > acls.sh):"; echo "$diff" | sed 's/^/     /'
fi
if grep -q -- '--bootstrap-server kafka:29092 --command-config /opt/oj/kafka/admin-client.properties' kafka/acls.sh 2>/dev/null \
  && grep -q -- '--add' kafka/acls.sh && grep -q -- '--list' kafka/acls.sh; then
  ok "kafka/acls.sh adds through kafka:29092 with the admin client config and ends with --list"
else bad "kafka/acls.sh adds through kafka:29092 with the admin client config and ends with --list"; fi
want_props='security.protocol=SSL
ssl.keystore.location=/etc/oj/tls/keystore.pem
ssl.keystore.type=PEM
ssl.truststore.location=/etc/oj/tls/ca.crt
ssl.truststore.type=PEM'
if [[ $(grep -v -e '^#' -e '^$' kafka/admin-client.properties 2>/dev/null | sort) == "$want_props" ]]; then
  ok "kafka/admin-client.properties: SSL with the PEM keystore and CA of the kafka-admin subpath"
else bad "kafka/admin-client.properties: SSL with the PEM keystore and CA of the kafka-admin subpath"; fi

# The resolved compose file. `config` prints a literal $ in its canonical escaped form $$ (a container receives one $),
# so values are compared after undoing that escape.
# Same lookup order as tests/compose.test.sh: $OJ_ENV_DIR, else this checkout when it has a .env, else the main checkout.
if [[ -n ${OJ_ENV_DIR:-} ]]; then deploy_dir=$OJ_ENV_DIR
elif [[ -f .env ]]; then deploy_dir=$PWD
else deploy_dir=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)"); fi
config=$(docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --format json)
check() { # check <description> <python expression over s = services; e = kafka's environment with $$ undone>
  if python3 -c "import json,sys; c=json.load(sys.stdin); s=c['services']; e={k: str(v).replace('\$\$', '\$') for k, v in s['kafka']['environment'].items()}; sys.exit(0 if ($2) else 1)" <<< "$config"; then
    ok "$1"
  else bad "$1"; fi
}
check "kafka maps a certificate to its CN: RULE:^CN=([^,]+)\$/\$1/,DEFAULT" \
  "e.get('KAFKA_SSL_PRINCIPAL_MAPPING_RULES') == r'RULE:^CN=([^,]+)\$/\$1/,DEFAULT'"
# Compose v5 happens to pass an unescaped \$/ or \$1 through, but the file's rule is that every literal \$ is written \$\$.
if grep -qF 'KAFKA_SSL_PRINCIPAL_MAPPING_RULES: RULE:^CN=([^,]+)$$/$$1/,DEFAULT' docker-compose.yml; then
  ok "docker-compose.yml writes the mapping rule's \$ as \$\$"
else bad "docker-compose.yml writes the mapping rule's \$ as \$\$"; fi
check "kafka authorizes with StandardAuthorizer; super users are kafka, kafka-admin and ANONYMOUS (loopback LOCAL)" \
  "e.get('KAFKA_AUTHORIZER_CLASS_NAME') == 'org.apache.kafka.metadata.authorizer.StandardAuthorizer' and e.get('KAFKA_SUPER_USERS') == 'User:kafka;User:kafka-admin;User:ANONYMOUS'"
check "kafka-init runs kafka/acls.sh once in apache/kafka:3.8.1 on oj-net as kafka-admin, after kafka is healthy" \
  "(lambda k: k['image'] == 'apache/kafka:3.8.1' and k.get('entrypoint') == ['/bin/bash', '/opt/oj/kafka/acls.sh'] and k.get('restart') == 'no' and list(k.get('networks', {})) == ['oj-net'] and {n: d['condition'] for n, d in k['depends_on'].items()} == {'tls-init': 'service_completed_successfully', 'kafka': 'service_healthy'} and any(m.get('type') == 'bind' and m['source'].endswith('/kafka') and m['target'] == '/opt/oj/kafka' and m.get('read_only') is True for m in k['volumes']) and any(m.get('source') == 'tls' and m.get('volume', {}).get('subpath') == 'kafka-admin' and m['target'] == '/etc/oj/tls' for m in k['volumes']))(s.get('kafka-init', {'image': None}))"
check "problem-service, submission-service and judge-worker start only after kafka-init wrote the ACLs" \
  "all(s[n]['depends_on'].get('kafka-init', {}).get('condition') == 'service_completed_successfully' for n in ('problem-service', 'submission-service', 'judge-worker'))"

exit $fail
