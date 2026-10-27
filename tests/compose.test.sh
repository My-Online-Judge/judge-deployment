#!/usr/bin/env bash
# Checks on the resolved compose file (sub-project 4). Prints key names only, never a value.
# Run from anywhere: tests/compose.test.sh — needs the gitignored .env* files beside docker-compose.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
# The directory that holds the .env files: $OJ_ENV_DIR (an override), else this checkout when it has a .env (a worktree
# the files were copied into), else the main checkout (as bench/lib/common.sh resolves it). Same order as tests/tls.test.sh.
if [[ -n ${OJ_ENV_DIR:-} ]]; then deploy_dir=$OJ_ENV_DIR
elif [[ -f .env ]]; then deploy_dir=$PWD
else deploy_dir=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)"); fi
# Grafana's admin password is required (:?); the checks never read its value.
export GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-dummy}
config=$(docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --format json)
# The same file before interpolation: which ${VARIABLE} a value names, not what it resolves to.
raw=$(docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --no-interpolate --format json)
fail=0
_check() { # _check <json> <description> <python expression over s = services, v = volumes>
  if python3 -c "import json,re,sys; c=json.load(sys.stdin); s=c['services']; v=c.get('volumes',{}); sys.exit(0 if ($3) else 1)" <<< "$1"; then
    echo "ok   $2"
  else
    echo "FAIL $2"; fail=1
  fi
}
check() { _check "$config" "$@"; }
check_raw() { _check "$raw" "$@"; }

worker_allowlist="['JUDGE_SERVER_TOKEN','JUDGE_SERVER_URL','KAFKA_BROKERS','MINIO_ACCESS_KEY','MINIO_BUCKET','MINIO_ENDPOINT',
  'MINIO_SECRET_KEY','OJ_TLS_DIR','OTEL_EXPORTER_OTLP_CERTIFICATE','OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE',
  'OTEL_EXPORTER_OTLP_CLIENT_KEY','OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL','OTEL_LOGS_EXPORTER',
  'OTEL_METRICS_EXPORTER','OTEL_SERVICE_NAME','SANDBOX_HEARTBEAT_URL','TZ']"
# The resolved config inlines an env_file into environment, so this one check also catches an env_file coming back.
check "judge-worker gets exactly the variables it reads" "sorted(s['judge-worker']['environment']) == $worker_allowlist"
# The run lane (Run code design §9): the judge-worker image on its own topics, with no MinIO and no heartbeat relay.
run_worker_allowlist="sorted(['CONSUMER_GROUP','JUDGED_TOPIC','JUDGE_INFRA_RETRY_SECONDS','JUDGE_SERVER_TOKEN','JUDGE_SERVER_URL',
  'KAFKA_BROKERS','OJ_TLS_DIR','OTEL_EXPORTER_OTLP_CERTIFICATE','OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE','OTEL_EXPORTER_OTLP_CLIENT_KEY',
  'OTEL_EXPORTER_OTLP_ENDPOINT','OTEL_EXPORTER_OTLP_PROTOCOL','OTEL_LOGS_EXPORTER','OTEL_METRICS_EXPORTER','OTEL_SERVICE_NAME',
  'REQUESTED_TOPIC','TZ'])"
check "run-worker gets exactly the variables it reads (no MinIO, no heartbeat relay)" "sorted(s['run-worker']['environment']) == $run_worker_allowlist"
check "run-worker consumes run.requested as run-workers, answers on run.judged, retries infra for 30 s" \
  "{k: s['run-worker']['environment'].get(k) for k in ('REQUESTED_TOPIC', 'JUDGED_TOPIC', 'CONSUMER_GROUP', 'JUDGE_INFRA_RETRY_SECONDS')} == {'REQUESTED_TOPIC': 'run.requested', 'JUDGED_TOPIC': 'run.judged', 'CONSUMER_GROUP': 'run-workers', 'JUDGE_INFRA_RETRY_SECONDS': '30'}"
check "run-worker is the judge-worker image on both networks with its own certificate, two replicas, no bundle cache" \
  "s['run-worker']['image'] == s['judge-worker']['image'] and set(s['run-worker']['networks']) == {'oj-net', 'sandbox-net'} and any(m.get('volume', {}).get('subpath') == 'run-worker' for m in s['run-worker']['volumes'] if m.get('source') == 'tls') and not any(m.get('source') == 'test_case_cache' for m in s['run-worker']['volumes']) and s['run-worker'].get('deploy', {}).get('replicas') == 2"
check_raw "run-worker calls both sandboxes over https" \
  "s['run-worker']['environment'].get('JUDGE_SERVER_URL') == 'https://judge-server:8080,https://judge-server-2:8080'"

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

# The sandboxes' API over mutual TLS (task 12): gunicorn serves 8080 with the certificate of the sandbox's own tls subpath
# and requires a client certificate signed by the CA (--cert-reqs=2 is ssl.CERT_REQUIRED). The worker calls both over
# https (a literal: the names are the certificates' SANs), and the healthcheck presents the sandbox's own certificate.
sandbox_gunicorn="['--certfile=/etc/oj/tls/tls.crt', '--keyfile=/etc/oj/tls/tls.key', '--ca-certs=/etc/oj/tls/ca.crt', '--cert-reqs=2']"
check "sandboxes serve https with the certificate of their own tls subpath and require a client certificate (--cert-reqs=2)" \
  "all(s[n]['environment'].get('GUNICORN_CMD_ARGS', '').split() == $sandbox_gunicorn and s[n]['environment'].get('SERVICE_URL') == f'https://{n}:8080' and any(m.get('volume', {}).get('subpath') == n for m in s[n].get('volumes', []) if m.get('source') == 'tls') for n in $sandboxes)"
SANDBOX_HEALTH='import hashlib,os,ssl,urllib.request as u; c=ssl.create_default_context(cafile="/etc/oj/tls/ca.crt"); c.load_cert_chain("/etc/oj/tls/tls.crt","/etc/oj/tls/tls.key"); t=hashlib.sha256(os.environ["TOKEN"].encode()).hexdigest(); u.urlopen(u.Request("https://localhost:8080/ping",data=b"{}",headers={"X-Judge-Server-Token":t,"Content-Type":"application/json"}),timeout=3,context=c)' \
  check "sandbox healthcheck pings /ping over mutual TLS with the sandbox's own certificate" \
  "all(s[n]['healthcheck']['test'] == ['CMD', 'python3', '-c', __import__('os').environ['SANDBOX_HEALTH']] for n in $sandboxes)"
check_raw "judge-worker calls both sandboxes over https, never http:// (a literal, not from .env)" \
  "s['judge-worker']['environment'].get('JUDGE_SERVER_URL') == 'https://judge-server:8080,https://judge-server-2:8080' and 'http://' not in s['judge-worker']['environment']['JUDGE_SERVER_URL']"
# OTLP to Jaeger over mutual TLS (task 13): Jaeger runs jaeger/config.yaml (tests/jaeger-config.test.sh) with the
# certificate of its own tls subpath, and every traced service exports over https with the CA and its own certificate.
check "jaeger runs jaeger/config.yaml, mounted read-only at /etc/jaeger/config.yaml, with the jaeger tls subpath" \
  "s['jaeger'].get('command') == ['--config', 'file:/etc/jaeger/config.yaml'] and any(m.get('type') == 'bind' and m['source'].endswith('/jaeger/config.yaml') and m['target'] == '/etc/jaeger/config.yaml' and m.get('read_only') is True for m in s['jaeger'].get('volumes', [])) and any(m.get('volume', {}).get('subpath') == 'jaeger' for m in s['jaeger'].get('volumes', []) if m.get('source') == 'tls')"
otlp_tls="{'OTEL_EXPORTER_OTLP_ENDPOINT': 'https://jaeger:4318', 'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/protobuf',
  'OTEL_EXPORTER_OTLP_CERTIFICATE': '/etc/oj/tls/ca.crt', 'OTEL_EXPORTER_OTLP_CLIENT_KEY': '/etc/oj/tls/tls.key',
  'OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE': '/etc/oj/tls/tls.crt'}"
check "the gateway, the three services and the worker export OTLP/HTTP to https://jaeger:4318 with the CA and their own certificate" \
  "sorted(n for n, x in s.items() if 'OTEL_SERVICE_NAME' in (x.get('environment') or {})) == ['api-gateway', 'identity-service', 'judge-worker', 'problem-service', 'run-worker', 'submission-service'] and all({k: x['environment'].get(k) for k in $otlp_tls} == $otlp_tls and any(m.get('source') == 'tls' for m in x.get('volumes', [])) for x in s.values() if 'OTEL_SERVICE_NAME' in (x.get('environment') or {}))"

# The HTTPS edge (task 14): Caddy is the one service on non-loopback host ports (80, 443). The portal and the gateway
# publish nothing; on oj-net they serve TLS and answer only the edge's certificate (portal/nginx-tls.conf; the gateway's
# tls profile). The portal calls the API on its own origin, and identity's cookies are Secure.
check "only edge publishes non-loopback host ports" \
  "{n for n, x in s.items() for p in x.get('ports', []) if p.get('host_ip') not in ('127.0.0.1', '::1')} == {'edge'}"
check "api-gateway and judge-portal publish nothing" \
  "not s['api-gateway'].get('ports') and not s['judge-portal'].get('ports')"
check "every Java service runs with SPRING_PROFILES_INCLUDE=tls" \
  "all('tls' in s[n]['environment'].get('SPRING_PROFILES_INCLUDE', '').split(',') for n in $java_services)"
check "edge runs caddy:2.11.7-alpine on 80 and 443 with edge/Caddyfile, the caddydata volume and the edge tls subpath" \
  "(lambda e: e['image'] == 'caddy:2.11.7-alpine' and sorted((str(p['published']), p['target']) for p in e.get('ports', [])) == [('443', 443), ('80', 80)] and any(m.get('type') == 'bind' and m['source'].endswith('/edge/Caddyfile') and m['target'] == '/etc/caddy/Caddyfile' and m.get('read_only') is True for m in e['volumes']) and any(m.get('source') == 'caddydata' and m['target'] == '/data' for m in e['volumes']) and 'caddydata' in v and any(m.get('volume', {}).get('subpath') == 'edge' for m in e['volumes'] if m.get('source') == 'tls'))(s.get('edge', {'image': None}))"
check "edge is capped at 128 MiB and healthy when Caddy's admin API (127.0.0.1:2019, in the container) answers" \
  "s['edge'].get('mem_limit') in (134217728, '134217728') and s['edge'].get('healthcheck', {}).get('test') == ['CMD', 'wget', '-q', '-O', '/dev/null', 'http://127.0.0.1:2019/config/']"
check_raw "edge and api-gateway get OJ_PUBLIC_HOST, default localhost (the site address; the gateway's CORS origin)" \
  "all(s.get(n, {}).get('environment', {}).get('OJ_PUBLIC_HOST') == '\${OJ_PUBLIC_HOST:-localhost}' for n in ('edge', 'api-gateway'))"
check "judge-portal serves portal/nginx-tls.conf with the judge-portal tls subpath, built with VITE_API_BASE_URL=/api/v1" \
  "(lambda p: (p['build'].get('args') or {}).get('VITE_API_BASE_URL') == '/api/v1' and any(m.get('type') == 'bind' and m['source'].endswith('/portal/nginx-tls.conf') and m['target'] == '/etc/nginx/nginx.conf' and m.get('read_only') is True for m in p.get('volumes', [])) and any(m.get('volume', {}).get('subpath') == 'judge-portal' for m in p.get('volumes', []) if m.get('source') == 'tls'))(s['judge-portal'])"
check "identity-service marks its cookies Secure (APP_COOKIE_SECURE)" \
  "s['identity-service']['environment'].get('APP_COOKIE_SECURE') == 'true'"

# No hop is left on plain HTTP (task 16): no compose environment value names a service by an http:// URL. The mock
# sandbox overlay is the one exception and is checked below, with its own overlay.
check "no environment value in docker-compose.yml is an http:// URL of a stack service" \
  "not any(re.search(r'http://(identity|problem|submission)-service|http://api-gateway|http://minio|http://jaeger|http://judge-server', str(val)) for x in s.values() for val in (x.get('environment') or {}).values())"

# Log rotation and image references (sp12 task 14). Compose resolves the nested default ${OJ_X_TAG:-${OJ_TAG:-main}} itself;
# the second config below proves it. The unset variables keep the operator's shell from deciding the first.
check "every service (the one-shots too) rotates its json-file logs: max-size 10m, max-file 3" \
  "all(x.get('logging') == {'driver': 'json-file', 'options': {'max-size': '10m', 'max-file': '3'}} for x in s.values())"
built="{'identity-service': 'oj-identity-service', 'problem-service': 'oj-problem-service', 'submission-service': 'oj-submission-service', 'api-gateway': 'oj-api-gateway', 'judge-worker': 'judge-worker', 'run-worker': 'judge-worker', 'judge-portal': 'judge-portal'}"
default_cfg=$(env -u OJ_TAG -u OJ_REGISTRY -u OJ_IDENTITY_TAG -u OJ_PROBLEM_TAG -u OJ_SUBMISSION_TAG -u OJ_GATEWAY_TAG -u OJ_WORKER_TAG -u OJ_PORTAL_TAG \
  docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --format json)
_check "$default_cfg" "built services reference ghcr.io/my-online-judge/<name>:main and keep their build" \
  "all(s[n]['image'] == f'ghcr.io/my-online-judge/{img}:main' and s[n].get('build') for n, img in $built.items())"
tagged_cfg=$(env -u OJ_REGISTRY -u OJ_PROBLEM_TAG -u OJ_SUBMISSION_TAG -u OJ_GATEWAY_TAG -u OJ_WORKER_TAG -u OJ_PORTAL_TAG OJ_TAG=t1 OJ_IDENTITY_TAG=t2 \
  docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" config --format json)
_check "$tagged_cfg" "OJ_IDENTITY_TAG beats OJ_TAG: identity is :t2, every other built service :t1" \
  "all(s[n]['image'].endswith(':t2' if n == 'identity-service' else ':t1') for n in $built)"
check "both sandboxes run qduoj pinned by digest" \
  "all(s[n]['image'] == 'docker.io/qduoj/judge-server@sha256:a580a1643277b4ec5a103a46fe1dbfe8537c437996955f82a5a22801ec73239e' for n in $sandboxes)"

# Exporters (sp12 task 15). Six serve /metrics over mutual TLS with the leaf of their own tls subpath, as the image's own
# user (the owner pki/identities.txt gives that subpath); cAdvisor has no TLS and stays plain HTTP on oj-net. None
# publishes a port. mem_limit is controller ruling Q4; the resolved config prints bytes.
exporter_images="{'node-exporter': 'prom/node-exporter:v1.12.1', 'cadvisor': 'ghcr.io/google/cadvisor:v0.60.6',
  'identity-db-exporter': 'prometheuscommunity/postgres-exporter:v0.17.1', 'problem-db-exporter': 'prometheuscommunity/postgres-exporter:v0.17.1',
  'submission-db-exporter': 'prometheuscommunity/postgres-exporter:v0.17.1', 'redis-exporter': 'oliver006/redis_exporter:v1.94.0',
  'kafka-exporter': 'danielqsj/kafka-exporter:v1.9.0'}"
tls_exporters="{'node-exporter': '65534:65534', 'identity-db-exporter': '65534:65534', 'problem-db-exporter': '65534:65534',
  'submission-db-exporter': '65534:65534', 'redis-exporter': '59000:59000', 'kafka-exporter': '65534:65534'}"
db_exporters="{'identity-db-exporter': 'identity-db', 'problem-db-exporter': 'problem-db', 'submission-db-exporter': 'submission-db'}"
check "the seven exporters run exactly their pinned images" \
  "all(s.get(n, {}).get('image') == i for n, i in $exporter_images.items())"
check "no exporter publishes a port; each sits on oj-net only and restarts unless stopped (kafka-exporter exits while Kafka is away)" \
  "all(n in s and not s[n].get('ports') and list(s[n].get('networks', {})) == ['oj-net'] and s[n].get('restart') == 'unless-stopped' for n in $exporter_images)"
check "exporter memory caps: cadvisor 256 MiB, the six others 64 MiB each" \
  "all(s.get(n, {}).get('mem_limit') in ((268435456, '268435456') if n == 'cadvisor' else (67108864, '67108864')) for n in $exporter_images)"
check "the six TLS exporters mount their own tls subpath read-only and wait for tls-init; cadvisor mounts no tls" \
  "all(n in s and [m.get('volume', {}).get('subpath') for m in s[n].get('volumes', []) if m.get('source') == 'tls'] == [n] and s[n]['depends_on']['tls-init']['condition'] == 'service_completed_successfully' for n in $tls_exporters) and not any(m.get('source') == 'tls' for m in s.get('cadvisor', {}).get('volumes', []))"
check "each TLS exporter runs as its image's own user (no user override), the owner pki/identities.txt gives its subpath" \
  "(lambda ids: all(n in s and 'user' not in s[n] and ids.get(n) == u for n, u in $tls_exporters.items()))({l.split()[0]: l.split()[1] for l in open('pki/identities.txt') if l.strip() and not l.startswith('#')})"
check "config exporter-web: TLS with the subpath's leaf, a CA-signed client certificate required" \
  "__import__('yaml').safe_load(c.get('configs', {}).get('exporter-web', {}).get('content', '')) == {'tls_server_config': {'cert_file': '/etc/oj/tls/tls.crt', 'key_file': '/etc/oj/tls/tls.key', 'client_ca_file': '/etc/oj/tls/ca.crt', 'client_auth_type': 'RequireAndVerifyClientCert'}}"
check "node-exporter shares the host pid namespace, reads /proc, /sys and / read-only, and serves exporter-web" \
  "(lambda x: x.get('pid') == 'host' and {(m['source'], m['target']) for m in x.get('volumes', []) if m.get('type') == 'bind' and m.get('read_only') is True} == {('/proc', '/host/proc'), ('/sys', '/host/sys'), ('/', '/rootfs')} and x.get('command') == ['--path.procfs=/host/proc', '--path.sysfs=/host/sys', '--path.rootfs=/rootfs', '--web.config.file=/etc/oj/exporter-web.yml'] and {'source': 'exporter-web', 'target': '/etc/oj/exporter-web.yml'} in [{k: y[k] for k in ('source', 'target')} for y in x.get('configs', [])])(s.get('node-exporter', {}))"
check "cadvisor reads docker.sock and containerd.sock read-only, is not privileged, and collects only cpu and memory" \
  "(lambda x: not x.get('privileged') and {(m['source'], m['target']) for m in x.get('volumes', []) if m.get('type') == 'bind' and m.get('read_only') is True} == {('/', '/rootfs'), ('/var/run/docker.sock', '/var/run/docker.sock'), ('/run/containerd/containerd.sock', '/run/containerd/containerd.sock'), ('/sys', '/sys'), ('/var/lib/docker', '/var/lib/docker')} and x.get('command') == ['--docker_only=true', '--store_container_labels=false', '--housekeeping_interval=15s', '--enable_metrics=cpu,memory'])(s.get('cadvisor', {}))"
check "each postgres-exporter connects to its own database as oj_monitor over verify-full TLS with its client certificate, after the database is healthy" \
  "all(n in s and s[n]['environment'].get('DATA_SOURCE_URI') == f'{db}:5432/postgres?sslmode=verify-full&sslrootcert=/etc/oj/tls/ca.crt&sslcert=/etc/oj/tls/tls.crt&sslkey=/etc/oj/tls/tls.key' and s[n]['environment'].get('DATA_SOURCE_USER') == 'oj_monitor' and s[n].get('command') == ['--web.config.file=/etc/oj/exporter-web.yml'] and {'source': 'exporter-web', 'target': '/etc/oj/exporter-web.yml'} in [{k: y[k] for k in ('source', 'target')} for y in s[n].get('configs', [])] and {k: d['condition'] for k, d in s[n]['depends_on'].items()} == {'tls-init': 'service_completed_successfully', db: 'service_healthy'} for n, db in $db_exporters.items())"
check_raw "the postgres-exporters' password is \${PG_MONITOR_PASSWORD:?run migrations/sp12-env.sh}" \
  "all(s.get(n, {}).get('environment', {}).get('DATA_SOURCE_PASS') == '\${PG_MONITOR_PASSWORD:?run migrations/sp12-env.sh}' for n in $db_exporters)"
check "redis-exporter reads rediss://redis:6379 with its client certificate and serves /metrics over mutual TLS" \
  "s.get('redis-exporter', {}).get('command') == ['-redis.addr=rediss://redis:6379', '-tls-ca-cert-file=/etc/oj/tls/ca.crt', '-tls-client-cert-file=/etc/oj/tls/tls.crt', '-tls-client-key-file=/etc/oj/tls/tls.key', '-tls-server-cert-file=/etc/oj/tls/tls.crt', '-tls-server-key-file=/etc/oj/tls/tls.key', '-tls-server-ca-cert-file=/etc/oj/tls/ca.crt']"
check "kafka-exporter reads kafka:29092 over TLS (name kafka) with its client certificate, serves mutual TLS, and starts after kafka-init" \
  "s.get('kafka-exporter', {}).get('command') == ['--kafka.server=kafka:29092', '--tls.enabled', '--tls.server-name=kafka', '--tls.ca-file=/etc/oj/tls/ca.crt', '--tls.cert-file=/etc/oj/tls/tls.crt', '--tls.key-file=/etc/oj/tls/tls.key', '--server.tls.enabled', '--server.tls.mutual-auth-enabled', '--server.tls.ca-file=/etc/oj/tls/ca.crt', '--server.tls.cert-file=/etc/oj/tls/tls.crt', '--server.tls.key-file=/etc/oj/tls/tls.key'] and {k: d['condition'] for k, d in s['kafka-exporter']['depends_on'].items()} == {'tls-init': 'service_completed_successfully', 'kafka-init': 'service_completed_successfully'}"

# Non-root containers (sp12 task 13). volume-init hands the test-case cache to uid 10001 before the worker (which runs as
# 10001) writes it; the one-shot has no network. The check allows only `logging` (and compose's null `command`) beyond the definition, in one place.
# It changes the owner only (sp13): compose runs it again on every `up` of the worker, and a checker bundle keeps group 12003.
check "volume-init: alpine one-shot that gives the test_case_cache volume to owner 10001 and keeps each group, no network" \
  "(lambda x: {k: val for k, val in x.items() if k not in ('logging', 'command')} == {'image': 'alpine:3.22', 'restart': 'no', 'network_mode': 'none', 'volumes': [{'type': 'volume', 'source': 'test_case_cache', 'target': '/test_case', 'volume': {}}], 'entrypoint': ['/bin/sh', '-c', 'chown -R 10001 /test_case']})(s.get('volume-init', {}))"
check "judge-worker waits for volume-init to complete" \
  "s['judge-worker']['depends_on'].get('volume-init', {}).get('condition') == 'service_completed_successfully'"
# A checker bundle's directory and inputs go to group 12003, qduoj's spj, which runs the checker; a submission (code,
# 12002) is not in it (sp13). The worker can give its files only to a group it is in.
check "judge-worker joins group 12003 (qduoj's spj) and nothing else, as uid 10001 (its image's user)" \
  "s['judge-worker'].get('group_add') == ['12003'] and 'user' not in s['judge-worker']"

# Grafana (sp12 task 18).
check "grafana: grafana-oss 13.0.2 on loopback 127.0.0.1:3000 only, oj-net only, restarts unless stopped, mem_limit 256 MiB" \
  "(lambda g: g.get('image') == 'grafana/grafana-oss:13.0.2' and g.get('container_name') == 'oj-grafana' and [(p.get('host_ip'), p.get('published'), p.get('target')) for p in g.get('ports', [])] == [('127.0.0.1', '3000', 3000)] and list(g.get('networks', {})) == ['oj-net'] and g.get('restart') == 'unless-stopped' and g.get('mem_limit') in (268435456, '268435456'))(s.get('grafana', {}))"
check_raw "grafana: the admin password is \${GRAFANA_ADMIN_PASSWORD:?run migrations/sp12-env.sh}; sign-up and analytics are off" \
  "(lambda e: e.get('GF_SECURITY_ADMIN_PASSWORD') == '\${GRAFANA_ADMIN_PASSWORD:?run migrations/sp12-env.sh}' and e.get('GF_USERS_ALLOW_SIGN_UP') == 'false' and e.get('GF_ANALYTICS_REPORTING_ENABLED') == 'false' and e.get('GF_ANALYTICS_CHECK_FOR_UPDATES') == 'false')(s.get('grafana', {}).get('environment', {}))"
check "grafana: provisioning and dashboards are mounted read-only, its data is the named volume grafanadata, and it logs like the others" \
  "(lambda g: {(m['source'], m['target'], bool(m.get('read_only'))) for m in g.get('volumes', []) if m.get('type') == 'bind'} == {(m['source'], m['target'], True) for m in g.get('volumes', []) if m.get('type') == 'bind' and m['target'] in ('/etc/grafana/provisioning', '/var/lib/grafana/dashboards')} and len([m for m in g.get('volumes', []) if m.get('type') == 'bind']) == 2 and any(m.get('source') == 'grafanadata' and m.get('target') == '/var/lib/grafana' for m in g.get('volumes', [])) and 'grafanadata' in v and g.get('logging') == s['prometheus'].get('logging'))(s.get('grafana', {}))"

# The mock sandbox speaks plain HTTP: its overlay points the worker at http:// and nothing expects TLS of the mock.
mock=$(docker compose --project-directory "$deploy_dir" -f "$PWD/docker-compose.yml" -f "$PWD/docker-compose.mock.yml" config --format json)
_check "$mock" "with docker-compose.mock.yml the worker calls both mock sandboxes over http, and their healthcheck and SERVICE_URL expect no TLS" \
  "s['judge-worker']['environment'].get('JUDGE_SERVER_URL') == 'http://judge-server:8080,http://judge-server-2:8080' and all(s[n]['image'] == 'mock-judge-server' and 'https' not in str(s[n]['healthcheck']['test']) and s[n]['environment'].get('SERVICE_URL') == f'http://{n}:8080' for n in $sandboxes)"

exit $fail
