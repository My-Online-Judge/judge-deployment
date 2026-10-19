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

# (sections follow)

tls_probe_exit
