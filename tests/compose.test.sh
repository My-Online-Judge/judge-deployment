#!/usr/bin/env bash
# Checks on the resolved compose file (sub-project 4). Prints key names only, never a value.
# Run from anywhere: tests/compose.test.sh — needs the gitignored .env* files beside docker-compose.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
# The checkout that owns the .env files: in a worktree, the main checkout (as bench/lib/common.sh resolves it).
deploy_dir=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
config=$(docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --format json)
fail=0
check() { # check <description> <python expression over s = services, v = volumes>
  if python3 -c "import json,sys; c=json.load(sys.stdin); s=c['services']; v=c.get('volumes',{}); sys.exit(0 if ($2) else 1)" <<< "$config"; then
    echo "ok   $1"
  else
    echo "FAIL $1"; fail=1
  fi
}

worker_allowlist="['JUDGE_SERVER_TOKEN','JUDGE_SERVER_URL','KAFKA_BROKERS','MINIO_ACCESS_KEY','MINIO_BUCKET','MINIO_ENDPOINT',
  'MINIO_SECRET_KEY','OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL','OTEL_LOGS_EXPORTER','OTEL_METRICS_EXPORTER',
  'OTEL_SERVICE_NAME','SANDBOX_HEARTBEAT_URL','TZ']"
# The resolved config inlines an env_file into environment, so this one check also catches an env_file coming back.
check "judge-worker gets exactly the variables it reads" "sorted(s['judge-worker']['environment']) == $worker_allowlist"

check "kafka keeps its logs on the named volume kafkadata" \
  "s['kafka']['environment'].get('KAFKA_LOG_DIRS') == '/var/lib/kafka/data' and any(m.get('source') == 'kafkadata' and m.get('target') == '/var/lib/kafka/data' for m in s['kafka'].get('volumes', [])) and 'kafkadata' in v"
check "kafka has a fixed cluster id" "s['kafka']['environment'].get('CLUSTER_ID') == 'LL99FafWSZyhNAgsibWLog'"

check "api-gateway waits only for the back-ends to start, and for redis to be healthy" \
  "{k: d['condition'] for k, d in s['api-gateway']['depends_on'].items()} == {'submission-service': 'service_started', 'identity-service': 'service_started', 'problem-service': 'service_started', 'redis': 'service_healthy'}"
check "problem-service gets KAFKA_PARTITIONS" "s['problem-service']['environment'].get('KAFKA_PARTITIONS') == '6'"

check "redis keeps an append-only file on the named volume redisdata (revocations survive down/up)" \
  "s['redis'].get('command') == ['redis-server', '--appendonly', 'yes', '--appendfsync', 'everysec'] and any(m.get('source') == 'redisdata' and m.get('target') == '/data' for m in s['redis'].get('volumes', [])) and 'redisdata' in v"
java_services="('api-gateway', 'identity-service', 'problem-service', 'submission-service')"
check "the JVM services load the jvm-dns-security config as Security properties and set grpc-java's resolver cache to 1 s, agent kept (effect: tests/jvm-dns.test.sh)" \
  "all({'-Djava.security.properties=/opt/oj/jvm-dns.security', '-Dnetworkaddress.cache.ttl=1', '-javaagent:/otel/opentelemetry-javaagent.jar'} <= set(s[n]['environment']['JAVA_TOOL_OPTIONS'].split()) and {'source': 'jvm-dns-security', 'target': '/opt/oj/jvm-dns.security'} in [{k: x[k] for k in ('source', 'target')} for x in s[n].get('configs', [])] for n in $java_services) and c['configs']['jvm-dns-security']['content'].split() == ['networkaddress.cache.ttl=1', 'networkaddress.cache.negative.ttl=0']"

# The sandboxes run untrusted code: least privilege, and a network that reaches only the worker.
sandboxes="('judge-server', 'judge-server-2')"
check "sandboxes are not privileged and keep only the capabilities the judger uses" \
  "all(not s[n].get('privileged') and s[n].get('cap_drop') == ['ALL'] and sorted(s[n].get('cap_add', [])) == ['CHOWN', 'DAC_OVERRIDE', 'FOWNER', 'KILL', 'SETGID', 'SETUID'] for n in $sandboxes)"
check "sandboxes run read-only with no-new-privileges, compiling into an exec tmpfs /judger" \
  "all(s[n].get('read_only') is True and 'no-new-privileges:true' in s[n].get('security_opt', []) and any(t.startswith('/judger:exec') for t in s[n].get('tmpfs', [])) for n in $sandboxes)"
check "sandboxes sit only on the internal sandbox-net, which the worker also joins" \
  "c['networks']['sandbox-net'].get('internal') is True and all(list(s[n]['networks']) == ['sandbox-net'] for n in $sandboxes) and set(s['judge-worker']['networks']) == {'oj-net', 'sandbox-net'}"
check "sandboxes have stable hostnames (the registry is keyed by hostname) and no BACKEND_URL" \
  "all(s[n].get('hostname') == n and 'BACKEND_URL' not in s[n]['environment'] for n in $sandboxes)"
check "sandboxes are capped at 3 GiB, 6 CPUs and 1024 pids" \
  "all(s[n].get('mem_limit') in (3221225472, '3221225472') and float(s[n].get('cpus')) == 6 and s[n].get('pids_limit') == 1024 for n in $sandboxes)"
check "judge-server keeps /log on the named volume js1log, not a bind mount" \
  "not any(m.get('source', '').startswith('/') for m in s['judge-server'].get('volumes', [])) and any(m.get('source') == 'js1log' and m.get('target') == '/log' for m in s['judge-server'].get('volumes', [])) and 'js1log' in v"


# TLS (sub-project 10): tls-init distributes the certificates; every mount of the tls volume is read-only at /etc/oj/tls,
# takes the subpath named after the service (kafka-init and minio-init borrow kafka-admin and minio), and waits for tls-init.
check "tls-init copies pki/out into the tls volume and exits, with no network (pki/out holds the CA key)" \
  "s['tls-init']['image'] == 'alpine:3.22' and s['tls-init'].get('restart') == 'no' and s['tls-init'].get('network_mode') == 'none' and not s['tls-init'].get('networks') and s['tls-init'].get('entrypoint') == ['/bin/sh', '/install.sh'] and 'tls' in v and {(m['source'].rsplit('/', 1)[-1], m['target'], m.get('read_only') is True) for m in s['tls-init']['volumes'] if m['source'] != 'tls'} == {('out', '/pki', True), ('install.sh', '/install.sh', True), ('identities.txt', '/identities.txt', True)} and any(m.get('source') == 'tls' and m.get('target') == '/tls' and not m.get('read_only') for m in s['tls-init']['volumes'])"
check "every service mounting tls uses its own subpath read-only at /etc/oj/tls and waits for tls-init" \
  "all(len(ms) == 1 and ms[0].get('target') == '/etc/oj/tls' and ms[0].get('read_only') is True and ms[0].get('volume', {}).get('subpath') == {'kafka-init': 'kafka-admin', 'minio-init': 'minio'}.get(n, n) and s[n]['depends_on']['tls-init']['condition'] == 'service_completed_successfully' for n, ms in ((n, [m for m in x.get('volumes', []) if m.get('source') == 'tls']) for n, x in s.items() if n != 'tls-init') if ms)"

exit $fail
