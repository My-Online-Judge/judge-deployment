#!/usr/bin/env bash
# migrations/sp12-pg-monitor.sh against a throwaway postgres:16 (no network) and a temp .env (ENV_FILE): run twice, the
# role oj_monitor ends up in pg_monitor and logs in with the .env password, and nothing printed contains that password.
set -euo pipefail
cd "$(dirname "$0")/.."
c=sp12-pgmon-$$
docker=(docker --context default)
work=$(mktemp -d)
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cleanup() { "${docker[@]}" rm -f "$c" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

"${docker[@]}" run -d --rm --network none --name "$c" \
  -e POSTGRES_USER=oj -e POSTGRES_PASSWORD=throwaway -e POSTGRES_DB=ojdb postgres:16 >/dev/null
for _ in $(seq 60); do
  # the entrypoint restarts postgres after init; two consecutive answers over the socket mean it is final
  if "${docker[@]}" exec "$c" sh -c 'psql -At -U "$POSTGRES_USER" "$POSTGRES_DB" -c "select 1"' >/dev/null 2>&1; then
    sleep 1
    "${docker[@]}" exec "$c" sh -c 'psql -At -U "$POSTGRES_USER" "$POSTGRES_DB" -c "select 1"' >/dev/null 2>&1 && break
  fi
  sleep 1
done
sql() { "${docker[@]}" exec -i "$c" sh -c 'psql -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"'; }
# The image trusts 127.0.0.1; make TCP logins use scram, as the stack's pg-hba does, so a login proves the password.
"${docker[@]}" exec "$c" sh -c 'sed -i -E "s/^(host[[:space:]].*)trust\$/\\1scram-sha-256/" "$PGDATA/pg_hba.conf"'
sql <<< "SELECT pg_reload_conf();" >/dev/null

pw=$(openssl rand -hex 24)
printf 'KAFKA_BROKERS=kafka:29092\nPG_MONITOR_PASSWORD=%s\nREDIS_HOST=redis\n' "$pw" > "$work/.env"
run() { ENV_FILE="$work/.env" PG_CONTAINERS="$c" bash migrations/sp12-pg-monitor.sh 2>&1; }

rc=0; out1=$(run) || rc=$?
[[ $rc -eq 0 && $out1 == "ok $c" ]] && ok "first run exits 0 and prints ok <container>" || bad "first run (rc=$rc): [$out1]"
rc=0; out2=$(run) || rc=$?
[[ $rc -eq 0 && $out2 == "ok $c" ]] && ok "second run (role exists) exits 0 and prints ok <container>" || bad "second run (rc=$rc): [$out2]"
[[ $(sql <<< "SELECT pg_has_role('oj_monitor', 'pg_monitor', 'MEMBER');") == t ]] \
  && ok "oj_monitor is a member of pg_monitor" || bad "oj_monitor is a member of pg_monitor"
login() { # <password> -> current_user of a scram login over TCP, or psql's error
  PGPASSWORD=$1 "${docker[@]}" exec -e PGPASSWORD "$c" psql -h 127.0.0.1 -U oj_monitor -d postgres -Atc 'select current_user' 2>&1 || true
}
[[ $(login "$pw") == oj_monitor ]] && ok "oj_monitor logs in with the .env password (scram)" || bad "oj_monitor logs in with the .env password (scram)"
grep -q 'password authentication failed' <<< "$(login wrong-password)" \
  && ok "a wrong password is refused (the login above proved the password)" || bad "a wrong password is refused"
grep -qF -- "$pw" <<< "$out1$out2" && bad "the output contains the password" || ok "the output never contains the password"

printf 'PG_MONITOR_PASSWORD=\n' > "$work/.env"
rc=0; out=$(run) || rc=$?
[[ $rc -ne 0 && $out == *PG_MONITOR_PASSWORD* && $out != *"ok $c"* ]] \
  && ok "an empty PG_MONITOR_PASSWORD stops the script, naming the variable" || bad "empty PG_MONITOR_PASSWORD (rc=$rc): [$out]"

exit $fail
