#!/usr/bin/env bash
# TLS matrix against the running stack (sub-project 10). Sections are added by the tasks that turn TLS on per hop.
# Helpers: tests/lib/tls-probe.sh (self-tested by tests/tls-probe-self.test.sh).
cd "$(dirname "$0")/.."
source tests/lib/tls-probe.sh

# ---- postgres: TLS + a CA-signed client certificate required (task 4) -------------------------------------------
# _psql_error <host> <cert|nocert> <sslmode> -> psql's error text. The password is deliberately wrong: the answer
# "password authentication failed" can only come after the TLS stage and the client-certificate check passed.
_psql_error() { # <host> <cert|nocert> <sslmode> [tls-probe|rogue]
  local cert=""
  [[ $2 == cert ]] && cert="sslcert=/k/tls.crt sslkey=/k/tls.key"
  PROBE_IMAGE=postgres:16 _probe_run "${4:-tls-probe}" "install -d -m 700 /k && cp /t/tls.key /k/ && cp /t/tls.crt /k/ && chmod 600 /k/tls.key; \
    PGPASSWORD=wrong-password psql \"host=$1 dbname=postgres user=oj connect_timeout=10 sslmode=$3 sslrootcert=/t/ca.crt $cert\" -c 'select 1' 2>&1 || true"
}
expect_psql() { # <description> <host> <cert|nocert> <sslmode> <expected substring, a grep BRE> [tls-probe|rogue]
  local got; got=$(_psql_error "$2" "$3" "$4" "${6:-tls-probe}")
  if grep -qi -- "$5" <<< "$got"; then pass "$1"; else fail "$1: wanted '$5', got: $(head -c 200 <<< "$got" | tr '\n' ' ')"; fi
}
for db in identity-db problem-db submission-db; do
  expect_psql "$db: client certificate + verify-full passes TLS (wrong password is the first refusal)" "$db" cert verify-full "password authentication failed"
  expect_psql "$db: no client certificate is refused" "$db" nocert verify-full "certificate"
  expect_psql "$db: a client certificate from a foreign CA is refused" "$db" cert verify-full "unknown ca\|certificate" rogue
  expect_psql "$db: plaintext is refused" "$db" nocert disable "no pg_hba.conf entry"
done

# ---- redis: TLS only, a CA-signed client certificate required (task 5) -----------------------------------------
# _redis_cli <cert|nocert|plain> [tls-probe|rogue] -> redis-cli's answer to PING (or its error text). A rejected client
# certificate shows up as a connection error, never PONG.
_redis_cli() {
  local args="--tls --cacert /t/ca.crt"
  [[ $1 == cert ]] && args="$args --cert /t/tls.crt --key /t/tls.key"
  [[ $1 == plain ]] && args=""
  PROBE_IMAGE=redis:7-alpine _probe_run "${2:-tls-probe}" "redis-cli -h redis $args ping 2>&1 || true"
}
expect_redis() { # <description> <cert|nocert|plain> <PONG|error> [tls-probe|rogue]
  local got; got=$(_redis_cli "$2" "${4:-tls-probe}")
  if [[ $3 == PONG ]]; then
    if grep -q '^PONG' <<< "$got"; then pass "$1"; else fail "$1: wanted PONG, got: $(head -c 200 <<< "$got" | tr '\n' ' ')"; fi
  else
    if grep -q 'PONG' <<< "$got" || [[ -z $got ]]; then fail "$1: wanted an error, got: $(head -c 200 <<< "$got" | tr '\n' ' ')"; else pass "$1"; fi
  fi
}
expect_redis "redis: a client certificate from the CA gets PONG" cert PONG
expect_redis "redis: no client certificate is refused" nocert error
expect_redis "redis: a client certificate from a foreign CA is refused" cert error rogue
expect_redis "redis: plaintext is refused" plain error

# ---- kafka: listener INTERNAL is TLS with a CA-signed client certificate required (task 6) ----------------------
# The probe's request is not Kafka's protocol: an accepted client sees the broker close, a refused one TLS 1.3's alert.
probe_handshake kafka:29092 none fail
probe_handshake kafka:29092 rogue fail
probe_handshake kafka:29092 tls-probe ok
# The PLAINTEXT listener LOCAL is bound to the broker's loopback. Only "Connection refused" proves it: a failed name
# lookup (kafka down) or a connection that opens are both failures.
expect_refused() { # <description> <host:port>
  local got; got=$(_probe_run none "timeout 10 openssl s_client -connect '$2' </dev/null 2>&1 || true")
  if grep -q 'Connection refused' <<< "$got"; then pass "$1"; else fail "$1: wanted 'Connection refused', got: $(head -c 200 <<< "$got" | tr '\n' ' ')"; fi
}
expect_refused "kafka: the PLAINTEXT listener LOCAL is not reachable from another container" kafka:9092

# ---- kafka-acl: the principal is the certificate's CN, and a CN without ACLs may not publish (task 7) ------------
# tls-probe's certificate passes TLS (section kafka) but has no ACL: TopicAuthorizationException can only come after the
# handshake and the authentication passed. apache/kafka runs as appuser; --user 0 reads the root-only tls-probe subpath.
_kafka_produce() { # <topic> -> kafka-console-producer.sh's output, as tls-probe
  docker --context default run --rm --user 0 --network "${OJ_NET:-oj-net}" \
    --mount "type=volume,src=${TLS_VOLUME:-judge-deployment_tls},dst=/t,readonly,volume-subpath=tls-probe" \
    apache/kafka:3.8.1 sh -c "printf 'security.protocol=SSL\nssl.keystore.type=PEM\nssl.keystore.location=/t/keystore.pem\nssl.truststore.type=PEM\nssl.truststore.location=/t/ca.crt\n' > /tmp/probe.properties; \
    echo tls-probe | timeout 60 /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka:29092 --producer.config /tmp/probe.properties --topic '$1' 2>&1 || true" 2>&1
}
got=$(_kafka_produce submission.judged)
if grep -q 'TopicAuthorizationException' <<< "$got"; then pass "kafka-acl: tls-probe may not publish to submission.judged"
else fail "kafka-acl: tls-probe may not publish to submission.judged: wanted TopicAuthorizationException, got: $(tail -c 300 <<< "$got" | tr '\n' ' ')"; fi
got=$(_kafka_produce submission.started)
if grep -q 'TopicAuthorizationException' <<< "$got"; then pass "kafka-acl: tls-probe may not publish to submission.started"
else fail "kafka-acl: tls-probe may not publish to submission.started: wanted TopicAuthorizationException, got: $(tail -c 300 <<< "$got" | tr '\n' ' ')"; fi

# ---- apis: the services' API (8000) and actuator (8081) ports require a CA-signed client certificate (task 8) ------
# On the API port only allow-listed CNs get past the certificate check: tls-probe's CN is in no list, so 403 (before any
# routing; 8000 serves no actuator). The actuator port has no CN allowlist (Prometheus, the healthcheck), but it too
# demands a client certificate.
for svc in identity-service problem-service submission-service; do
  probe_http "https://$svc:8000/actuator/health" tls-probe 403
  probe_handshake "$svc:8000" none fail
  probe_plain_refused "$svc:8000"
  probe_http "https://$svc:8081/actuator/health" tls-probe 200
  probe_handshake "$svc:8081" none fail
done

# ---- gateway-worker: the gateway's actuator and the worker's /metrics require a CA-signed client certificate (task 9) -
# judge-worker has replicas and no container name: its service name resolves to one of them, and every replica's
# certificate names judge-worker.
probe_http "https://api-gateway:8081/actuator/health" tls-probe 200
probe_handshake "api-gateway:8081" none fail
probe_http "https://judge-worker:9100/metrics" tls-probe 200
probe_handshake "judge-worker:9100" none fail

# ---- grpc: problem-service's internal API (9090) requires a CA-signed client certificate and answers only the CN ----
# submission-service (task 10). grpcurl verifies problem-service's certificate against the CA and the name
# problem-service. tls-probe's CN is in no allowlist: PermissionDenied can only come after TLS and the client-certificate
# check passed. Without a certificate TLS 1.3 refuses after the handshake, with the alert "certificate required": grpc-go
# then retries until -max-time and only its warning log names the alert (GRPC_GO_LOG_SEVERITY_LEVEL). The proto is
# oj-common's, from the repo beside this one. The image runs as user grpcurl; --user 0 reads the root-only tls-probe
# subpath.
_grpcurl() { # <none|tls-probe> -> grpcurl's output for one GetJudgeSpec call
  local proto args=(-cacert /t/ca.crt)
  proto=$(cd ../oj-common/src/main/proto 2>/dev/null && pwd) || { echo "no ../oj-common/src/main/proto beside this repo"; return; }
  [[ $1 == tls-probe ]] && args+=(-cert /t/tls.crt -key /t/tls.key)
  docker --context default run --rm --user 0 --network "${OJ_NET:-oj-net}" -e GRPC_GO_LOG_SEVERITY_LEVEL=warning \
    --mount "type=volume,src=${TLS_VOLUME:-judge-deployment_tls},dst=/t,readonly,volume-subpath=tls-probe" \
    --mount "type=bind,src=$proto,dst=/proto,readonly" \
    fullstorydev/grpcurl:v1.9.1 "${args[@]}" -import-path /proto -proto problem_internal.proto -max-time 10 \
    -d '{"problem_slug": "tls-probe"}' problem-service:9090 oj.problem.v1.ProblemInternal/GetJudgeSpec 2>&1
}
expect_grpcurl() { # <description> <none|tls-probe> <expected substring>
  local got; got=$(_grpcurl "$2")
  if grep -q -- "$3" <<< "$got"; then pass "$1"; else fail "$1: wanted '$3', got: $(head -c 300 <<< "$got" | tr '\n' ' ')"; fi
}
expect_grpcurl "grpc: problem-service:9090 refuses tls-probe's CN with PermissionDenied" tls-probe "Code: PermissionDenied"
expect_grpcurl "grpc: problem-service:9090 refuses a caller without a client certificate" none "tls: certificate required"

# ---- minio: TLS with the minio certificate, and the worker's key may read the bucket but not write it (task 11) ----
# mc in MinIO's image verifies minio:9000 against the CA (SSL_CERT_FILE) and the name minio. The keys come from the env
# file of the checkout the stack runs from: $OJ_ENV_FILE if set, else this checkout's .env (a worktree deployed from, as in
# sub-project 10's rollout), else the main checkout's (found as tests/compose.test.sh finds it). They reach the container
# through its environment, never the command line; nothing prints them, and an empty key fails here instead of letting mc
# go anonymous. S3's AccessDenied, which mc cp words "Insufficient permissions to access this path", can only come after
# TLS and the key's signature were accepted (an unknown key reads "The Access Key Id you provided does not exist").
minio_env=${OJ_ENV_FILE:-}
if [[ -z $minio_env ]]; then
  if [[ -f .env ]]; then minio_env=$PWD/.env
  else minio_env=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")/.env; fi
fi
_env_value() { # <name> -> the value of <name> in $minio_env (last assignment wins, quotes dropped)
  grep -E "^$1=" "$minio_env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'
}
_mc_worker() { # <sh script using mc and $BUCKET> -> its output, with the alias oj = minio:9000 as the worker's MinIO user
  MC_AK=$(_env_value MINIO_WORKER_ACCESS_KEY) MC_SK=$(_env_value MINIO_WORKER_SECRET_KEY) BUCKET=$(_env_value MINIO_BUCKET) \
    docker --context default run --rm --network "${OJ_NET:-oj-net}" -e MC_AK -e MC_SK -e BUCKET \
    --mount "type=volume,src=${TLS_VOLUME:-judge-deployment_tls},dst=/t,readonly,volume-subpath=tls-probe" \
    --entrypoint /bin/sh ghcr.io/my-online-judge/minio:RELEASE.2025-09-07T16-13-09Z \
    -c "export SSL_CERT_FILE=/t/ca.crt MC_HOST_oj=\"https://\$MC_AK:\$MC_SK@minio:9000\"; $1" 2>&1
}
minio_missing=""
for v in MINIO_WORKER_ACCESS_KEY MINIO_WORKER_SECRET_KEY MINIO_BUCKET; do
  [[ -n $(_env_value "$v") ]] || minio_missing+=" $v"
done
if [[ -n $minio_missing ]]; then
  fail "minio: not probed, empty or missing in $minio_env:$minio_missing"
else
  got=$(_mc_worker 'mc ls "oj/$BUCKET" >/dev/null && echo LISTED')
  if grep -q '^LISTED$' <<< "$got"; then pass "minio: the worker's key lists the test-case bucket over verified TLS"
  else fail "minio: the worker's key lists the test-case bucket over verified TLS: got: $(head -c 300 <<< "$got" | tr '\n' ' ')"; fi
  got=$(_mc_worker 'echo tls-probe > /tmp/probe && mc cp /tmp/probe "oj/$BUCKET/tls-probe/denied" || true')
  if grep -qE 'Insufficient permissions to access this path|Access Denied' <<< "$got"; then
    pass "minio: the worker's key may not write to the test-case bucket (Access Denied)"
  else fail "minio: the worker's key may not write to the test-case bucket: wanted Access Denied, got: $(head -c 300 <<< "$got" | tr '\n' ' ')"; fi
fi

# ---- sandbox: the sandboxes' API (8080) requires a CA-signed client certificate (task 12) ------------------------
# Probed from oj-sandbox-net, the sandboxes' only network ($OJ_SANDBOX_NET for a scratch stack). gunicorn checks the CA,
# not the CN: tls-probe's certificate passes TLS, and the judge-server token still guards the API. To plaintext gunicorn
# 20.0.4 writes nothing and resets the connection.
for js in judge-server judge-server-2; do
  OJ_NET=${OJ_SANDBOX_NET:-oj-sandbox-net} probe_handshake "$js:8080" none fail
  OJ_NET=${OJ_SANDBOX_NET:-oj-sandbox-net} probe_handshake "$js:8080" rogue fail
  OJ_NET=${OJ_SANDBOX_NET:-oj-sandbox-net} probe_handshake "$js:8080" tls-probe ok
  OJ_NET=${OJ_SANDBOX_NET:-oj-sandbox-net} probe_plain_refused "$js:8080"
done

# ---- otlp: Jaeger's OTLP/HTTP receiver (4318) requires a CA-signed client certificate (task 13) -------------------
# Every traced service exports to https://jaeger:4318 with its own certificate (x-otel-env). Jaeger checks the CA, not
# the CN: tls-probe's certificate passes TLS, and the receiver answers the probe's GET / with a 404.
probe_handshake jaeger:4318 none fail
probe_handshake jaeger:4318 rogue fail
probe_handshake jaeger:4318 tls-probe ok

# ---- edge: the HTTPS edge is the way in; the gateway and the portal answer only its certificate (task 14) ---------
# tls-probe's certificate passes TLS on api-gateway:8000 and judge-portal:443 (signed by the CA), but its CN is not edge:
# 403 before any routing. Without a certificate the gateway refuses at TLS, and nginx answers 400. Through the edge a
# client needs no certificate, only trust in the edge's (here the CA; the probe connects by the name edge, in its SAN).
probe_handshake api-gateway:8000 tls-probe ok
probe_http https://api-gateway:8000/api/v1/problems tls-probe 403
probe_handshake api-gateway:8000 none fail
probe_http https://judge-portal:443/ tls-probe 403
probe_http https://judge-portal:443/ none 400
probe_http https://edge/api/v1/problems none 200
probe_http https://edge/ none 200
# Plain http on 80 only redirects, permanently, to the same URL on https.
got=$(docker --context default run --rm --network "${OJ_NET:-oj-net}" "$PROBE_IMAGE" sh -c \
  "printf 'GET /problems HTTP/1.1\r\nHost: edge\r\nConnection: close\r\n\r\n' | timeout 5 nc -w 3 edge 80" 2>&1 | tr -d '\r')
if grep -q '^HTTP/1.1 308 ' <<< "$got" && grep -qi '^Location: https://edge/problems$' <<< "$got"; then
  pass "edge: http://edge/problems -> 308 https://edge/problems"
else fail "edge: http://edge/problems -> 308 https://edge/problems: got: $(head -c 200 <<< "$got" | tr '\n' ' ')"; fi

# (sections follow)

tls_probe_exit
