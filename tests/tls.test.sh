#!/usr/bin/env bash
# TLS matrix against the running stack (sub-project 10). Sections are added by the tasks that turn TLS on per hop.
# Helpers: tests/lib/tls-probe.sh (self-tested by tests/tls-probe-self.test.sh).
cd "$(dirname "$0")/.."
source tests/lib/tls-probe.sh

# ---- postgres: TLS + a CA-signed client certificate required (task 4) -------------------------------------------
# _psql_error <host> <cert|nocert> <sslmode> -> psql's error text. The password is deliberately wrong: the answer
# "password authentication failed" can only come after the TLS stage and the client-certificate check passed.
_psql_error() {
  local cert=""
  [[ $2 == cert ]] && cert="sslcert=/k/tls.crt sslkey=/k/tls.key"
  PROBE_IMAGE=postgres:16 _probe_run tls-probe "install -d -m 700 /k && cp /t/tls.key /k/ && cp /t/tls.crt /k/ && chmod 600 /k/tls.key; \
    PGPASSWORD=wrong-password psql \"host=$1 dbname=postgres user=oj connect_timeout=10 sslmode=$3 sslrootcert=/t/ca.crt $cert\" -c 'select 1' 2>&1 || true"
}
expect_psql() { # <description> <host> <cert|nocert> <sslmode> <expected substring>
  local got; got=$(_psql_error "$2" "$3" "$4")
  if grep -qi -- "$5" <<< "$got"; then pass "$1"; else fail "$1: wanted '$5', got: $(head -c 200 <<< "$got" | tr '\n' ' ')"; fi
}
for db in identity-db problem-db submission-db; do
  expect_psql "$db: client certificate + verify-full passes TLS (wrong password is the first refusal)" "$db" cert verify-full "password authentication failed"
  expect_psql "$db: no client certificate is refused" "$db" nocert verify-full "certificate"
  expect_psql "$db: plaintext is refused" "$db" nocert disable "no pg_hba.conf entry"
done

# (sections follow)

tls_probe_exit
