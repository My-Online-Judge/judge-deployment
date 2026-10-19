#!/usr/bin/env bash
# Checks on the resolved compose file (sub-project 4). Prints key names only, never a value.
# Run from anywhere: tests/compose.test.sh — needs the gitignored .env* files beside docker-compose.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
# The checkout that owns the .env files: in a worktree, the main checkout (as bench/lib/common.sh resolves it).
deploy_dir=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
config=$(docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --format json)
# The same file before interpolation: which ${VARIABLE} a value names, not what it resolves to.
raw=$(docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --no-interpolate --format json)
fail=0
_check() { # _check <json> <description> <python expression over s = services, v = volumes>
  if python3 -c "import json,sys; c=json.load(sys.stdin); s=c['services']; v=c.get('volumes',{}); sys.exit(0 if ($3) else 1)" <<< "$1"; then
    echo "ok   $2"
  else
    echo "FAIL $2"; fail=1
  fi
}
check() { _check "$config" "$@"; }
check_raw() { _check "$raw" "$@"; }

worker_allowlist="['JUDGE_SERVER_TOKEN','JUDGE_SERVER_URL','KAFKA_BROKERS','MINIO_ACCESS_KEY','MINIO_BUCKET','MINIO_ENDPOINT',
  'MINIO_SECRET_KEY','OJ_TLS_DIR','OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL','OTEL_LOGS_EXPORTER',
  'OTEL_METRICS_EXPORTER','OTEL_SERVICE_NAME','SANDBOX_HEARTBEAT_URL','TZ']"
# The resolved config inlines an env_file into environment, so this one check also catches an env_file coming back.
check "judge-worker gets exactly the variables it reads" "sorted(s['judge-worker']['environment']) == $worker_allowlist"

check "kafka keeps its logs on the named volume kafkadata" \
  "s['kafka']['environment'].get('KAFKA_LOG_DIRS') == '/var/lib/kafka/data' and any(m.get('source') == 'kafkadata' and m.get('target') == '/var/lib/kafka/data' for m in s['kafka'].get('volumes', [])) and 'kafkadata' in v"
check "kafka has a fixed cluster id" "s['kafka']['environment'].get('CLUSTER_ID') == 'LL99FafWSZyhNAgsibWLog'"

check "api-gateway waits only for the back-ends to start, and for redis to be healthy" \
  "{k: d['condition'] for k, d in s['api-gateway']['depends_on'].items()} == {'tls-init': 'service_completed_successfully', 'submission-service': 'service_started', 'identity-service': 'service_started', 'problem-service': 'service_started', 'redis': 'service_healthy'}"
check "problem-service gets KAFKA_PARTITIONS" "s['problem-service']['environment'].get('KAFKA_PARTITIONS') == '6'"

check "redis keeps an append-only file on the named volume redisdata (revocations survive down/up)" \
  "'--appendonly' in s['redis']['command'] and s['redis']['command'][s['redis']['command'].index('--appendonly') + 1] == 'yes' and s['redis']['command'][s['redis']['command'].index('--appendfsync') + 1] == 'everysec' and any(m.get('source') == 'redisdata' and m.get('target') == '/data' for m in s['redis'].get('volumes', [])) and 'redisdata' in v"
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

# Postgres over mutual TLS (task 4): ssl on, a pg_hba that only admits hostssl + a CA-signed client certificate, and the
# three services connect with the tls profile (verify-full + their own client certificate).
check "each database serves TLS with the pg-hba file (hostssl only, clientcert=verify-ca) and the keys of its own tls subpath" \
  "all('ssl=on' in s[n]['command'] and 'hba_file=/etc/oj/pg_hba.conf' in s[n]['command'] and {'ssl_cert_file=/etc/oj/tls/tls.crt', 'ssl_key_file=/etc/oj/tls/tls.key', 'ssl_ca_file=/etc/oj/tls/ca.crt'} <= set(s[n]['command']) and 'timezone=Asia/Ho_Chi_Minh' in s[n]['command'] and {'source': 'pg-hba', 'target': '/etc/oj/pg_hba.conf'} in [{k: x[k] for k in ('source', 'target')} for x in s[n].get('configs', [])] and any(m.get('volume', {}).get('subpath') == n for m in s[n]['volumes'] if m.get('source') == 'tls') for n in ('identity-db', 'problem-db', 'submission-db')) and [' '.join(l.split()) for l in c['configs']['pg-hba']['content'].splitlines()] == ['local all all trust', 'hostssl all all 0.0.0.0/0 scram-sha-256 clientcert=verify-ca', 'hostssl all all ::/0 scram-sha-256 clientcert=verify-ca']"
check "identity, problem and submission services run with SPRING_PROFILES_INCLUDE=tls" \
  "all('tls' in s[n]['environment'].get('SPRING_PROFILES_INCLUDE', '').split(',') and any(m.get('source') == 'tls' for m in s[n]['volumes']) for n in ('identity-service', 'problem-service', 'submission-service'))"

# Redis over mTLS (task 5): plaintext port off, a CA-signed client certificate required, health probe uses the same certificate.
check "redis serves TLS only (--port 0), requires client certificates, and keeps the keys of its own tls subpath" \
  "(lambda c: c[:1] == ['redis-server'] and c[c.index('--port') + 1] == '0' and c[c.index('--tls-port') + 1] == '6379' and c[c.index('--tls-auth-clients') + 1] == 'yes' and c[c.index('--tls-cert-file') + 1] == '/etc/oj/tls/tls.crt' and c[c.index('--tls-key-file') + 1] == '/etc/oj/tls/tls.key' and c[c.index('--tls-ca-cert-file') + 1] == '/etc/oj/tls/ca.crt')(s['redis']['command']) and any(m.get('volume', {}).get('subpath') == 'redis' for m in s['redis']['volumes'] if m.get('source') == 'tls')"
check "redis healthcheck pings over TLS with its own certificate" \
  "s['redis']['healthcheck']['test'] == ['CMD', 'redis-cli', '--tls', '--cacert', '/etc/oj/tls/ca.crt', '--cert', '/etc/oj/tls/tls.crt', '--key', '/etc/oj/tls/tls.key', 'ping']"
check "api-gateway, identity-service and submission-service reach redis over TLS (tls profile + tls mount; gateway mounts the api-gateway subpath)" \
  "all('tls' in s[n]['environment'].get('SPRING_PROFILES_INCLUDE', '').split(',') and any(m.get('volume', {}).get('subpath') == n for m in s[n]['volumes'] if m.get('source') == 'tls') for n in ('api-gateway', 'identity-service', 'submission-service'))"

# Kafka over mTLS (task 6): INTERNAL and CONTROLLER speak TLS with required client certificates (PEM stores from the kafka
# subpath, host names verified); LOCAL is PLAINTEXT on the broker's loopback, for the in-container tools only. SSL:// in
# the advertised listeners would send the image's wrapper down its JKS-only path.
check "kafka maps CONTROLLER and INTERNAL to SSL and only LOCAL to PLAINTEXT" \
  "s['kafka']['environment'].get('KAFKA_LISTENER_SECURITY_PROTOCOL_MAP') == 'CONTROLLER:SSL,INTERNAL:SSL,LOCAL:PLAINTEXT'"
check "kafka binds LOCAL to 127.0.0.1 and advertises INTERNAL and LOCAL, never SSL://" \
  "(lambda e: e.get('KAFKA_LISTENERS') == 'INTERNAL://:29092,CONTROLLER://:9093,LOCAL://127.0.0.1:9092' and 'SSL://' not in e.get('KAFKA_ADVERTISED_LISTENERS', '') and e.get('KAFKA_ADVERTISED_LISTENERS') == 'INTERNAL://kafka:29092,LOCAL://127.0.0.1:9092')(s['kafka']['environment'])"
# (KAFKA_SSL_PRINCIPAL_MAPPING_RULES, the ACL principal: tests/kafka-acls.test.sh)
check "kafka requires client certificates and verifies host names, with unencrypted PEM stores from its own tls subpath" \
  "{k: v for k, v in s['kafka']['environment'].items() if k.startswith('KAFKA_SSL_') and k != 'KAFKA_SSL_PRINCIPAL_MAPPING_RULES'} == {'KAFKA_SSL_KEYSTORE_TYPE': 'PEM', 'KAFKA_SSL_KEYSTORE_LOCATION': '/etc/oj/tls/keystore.pem', 'KAFKA_SSL_TRUSTSTORE_TYPE': 'PEM', 'KAFKA_SSL_TRUSTSTORE_LOCATION': '/etc/oj/tls/ca.crt', 'KAFKA_SSL_CLIENT_AUTH': 'required', 'KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM': 'https'} and any(m.get('volume', {}).get('subpath') == 'kafka' for m in s['kafka'].get('volumes', []) if m.get('source') == 'tls')"
check "kafka's healthcheck lists topics over the loopback LOCAL listener" \
  "s['kafka']['healthcheck']['test'] == ['CMD-SHELL', '/opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list || exit 1']"
check "judge-worker finds its certificates at OJ_TLS_DIR=/etc/oj/tls, the judge-worker subpath" \
  "s['judge-worker']['environment'].get('OJ_TLS_DIR') == '/etc/oj/tls' and any(m.get('volume', {}).get('subpath') == 'judge-worker' for m in s['judge-worker'].get('volumes', []) if m.get('source') == 'tls')"

# Service APIs and actuators over mTLS (task 8): the healthcheck presents the service's own certificate to the actuator;
# Prometheus scrapes with the certificate of its own tls subpath.
check "identity, problem, submission and api-gateway healthchecks call the actuator over mutual TLS with their own certificate" \
  "all(s[n]['healthcheck']['test'] == ['CMD-SHELL', 'curl -fsS --cacert /etc/oj/tls/ca.crt --cert /etc/oj/tls/tls.crt --key /etc/oj/tls/tls.key https://localhost:8081/actuator/health | grep -q UP'] for n in ('identity-service', 'problem-service', 'submission-service', 'api-gateway'))"
check "prometheus mounts the prometheus tls subpath (its scrape client certificate)" \
  "any(m.get('volume', {}).get('subpath') == 'prometheus' for m in s['prometheus'].get('volumes', []) if m.get('source') == 'tls')"

# The gateway and the worker call the services over mTLS (task 9): https URIs, their own certificates (tls subpaths above).
check "api-gateway routes to the services over https on :8000" \
  "{k: s['api-gateway']['environment'].get(k) for k in ('SUBMISSION_URI', 'IDENTITY_URI', 'PROBLEM_URI')} == {'SUBMISSION_URI': 'https://submission-service:8000', 'IDENTITY_URI': 'https://identity-service:8000', 'PROBLEM_URI': 'https://problem-service:8000'}"
check "judge-worker relays the sandbox heartbeats to submission-service over https" \
  "s['judge-worker']['environment'].get('SANDBOX_HEARTBEAT_URL') == 'https://submission-service:8000/api/judge_server_heartbeat/'"

# problem-service's gRPC API knows its caller by the client certificate (task 10): the service token is retired, and
# submission-service dials problem-service by the name its certificate's SAN carries.
check "no service gets PROBLEM_RPC_TOKEN" \
  "all('PROBLEM_RPC_TOKEN' not in (x.get('environment') or {}) for x in s.values())"
check "submission-service dials problem-service's gRPC API by name" \
  "s['submission-service']['environment'].get('PROBLEM_GRPC_ADDRESS') == 'static://problem-service:9090'"

# MinIO over TLS with least-privilege keys (task 11): MinIO serves the certificate of its tls subpath; the one-shot
# minio-init creates the bucket, the two policies and the two users; problem-service and the worker each use their own
# key over https, never the root account.
check "minio serves TLS from its own tls subpath (--certs-dir /etc/oj/tls) and trusts the CA (SSL_CERT_FILE)" \
  "(lambda m: '--certs-dir' in m['command'] and m['command'][m['command'].index('--certs-dir') + 1] == '/etc/oj/tls' and m['environment'].get('SSL_CERT_FILE') == '/etc/oj/tls/ca.crt' and any(x.get('volume', {}).get('subpath') == 'minio' for x in m['volumes'] if x.get('source') == 'tls') and any(x.get('source') == 'miniodata' and x.get('target') == '/data' for x in m['volumes']))(s['minio'])"
check "minio's healthcheck asks mc ready over https, verifying the server against the CA" \
  "s['minio']['healthcheck']['test'] == ['CMD-SHELL', 'SSL_CERT_FILE=/etc/oj/tls/ca.crt MC_HOST_local=https://x:x@localhost:9000 mc ready local']"
check "minio-init runs minio/minio-init.sh once in minio's image on oj-net, with the minio subpath, after minio is healthy" \
  "(lambda k: k['image'] == s['minio']['image'] and k.get('entrypoint') == ['/bin/bash', '/opt/oj/minio/minio-init.sh'] and k.get('restart') == 'no' and list(k.get('networks', {})) == ['oj-net'] and {n: d['condition'] for n, d in k['depends_on'].items()} == {'tls-init': 'service_completed_successfully', 'minio': 'service_healthy'} and any(m.get('type') == 'bind' and m['source'].endswith('/minio') and m['target'] == '/opt/oj/minio' and m.get('read_only') is True for m in k['volumes']) and any(m.get('source') == 'tls' and m.get('volume', {}).get('subpath') == 'minio' for m in k['volumes']))(s.get('minio-init', {'image': None}))"
check "minio-init gets the root account, the two service keys, the bucket and the CA, nothing else" \
  "sorted(s.get('minio-init', {}).get('environment', {})) == ['MINIO_BUCKET', 'MINIO_PROBLEM_ACCESS_KEY', 'MINIO_PROBLEM_SECRET_KEY', 'MINIO_ROOT_PASSWORD', 'MINIO_ROOT_USER', 'MINIO_WORKER_ACCESS_KEY', 'MINIO_WORKER_SECRET_KEY', 'SSL_CERT_FILE'] and s['minio-init']['environment']['SSL_CERT_FILE'] == '/etc/oj/tls/ca.crt'"
check "problem-service and judge-worker reach MinIO at https://minio:9000, after minio-init" \
  "all(s[n]['environment'].get('MINIO_ENDPOINT') == 'https://minio:9000' and s[n]['depends_on'].get('minio-init', {}).get('condition') == 'service_completed_successfully' for n in ('problem-service', 'judge-worker'))"
check_raw "problem-service uses the problem key and judge-worker the worker key (MINIO_PROBLEM_* / MINIO_WORKER_*)" \
  "{k: s['problem-service']['environment'].get(k) for k in ('MINIO_ACCESS_KEY', 'MINIO_SECRET_KEY')} == {'MINIO_ACCESS_KEY': '\${MINIO_PROBLEM_ACCESS_KEY}', 'MINIO_SECRET_KEY': '\${MINIO_PROBLEM_SECRET_KEY}'} and {k: s['judge-worker']['environment'].get(k) for k in ('MINIO_ACCESS_KEY', 'MINIO_SECRET_KEY')} == {'MINIO_ACCESS_KEY': '\${MINIO_WORKER_ACCESS_KEY}', 'MINIO_SECRET_KEY': '\${MINIO_WORKER_SECRET_KEY}'}"
check_raw "only minio and minio-init get MinIO's root account" \
  "all('MINIO_ROOT' not in str(x.get('environment') or {}) for n, x in s.items() if n not in ('minio', 'minio-init'))"

exit $fail
