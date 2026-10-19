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
expect_psql() { # <description> <host> <cert|nocert> <sslmode> <expected substring> [tls-probe|rogue]
  local got; got=$(_psql_error "$2" "$3" "$4" "${6:-tls-probe}")
  if grep -qi -- "$5" <<< "$got"; then pass "$1"; else fail "$1: wanted '$5', got: $(head -c 200 <<< "$got" | tr '\n' ' ')"; fi
}
for db in identity-db problem-db submission-db; do
  expect_psql "$db: client certificate + verify-full passes TLS (wrong password is the first refusal)" "$db" cert verify-full "password authentication failed"
  expect_psql "$db: no client certificate is refused" "$db" nocert verify-full "certificate"
  expect_psql "$db: a client certificate from a foreign CA is refused" "$db" cert verify-full "certificate" rogue
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

# (sections follow)

tls_probe_exit
