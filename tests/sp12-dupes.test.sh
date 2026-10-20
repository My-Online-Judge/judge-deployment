#!/usr/bin/env bash
# migrations/sp12-dupes.sh against a throwaway postgres:16 (no network) holding a minimal t_users: live accounts that
# share a username or an email in any case, or a Google id, are listed one line each with their ids and the script
# exits 1; soft-deleted rows (status 2) and NULLs never count. Once they are resolved it prints "no duplicates" and
# exits 0. With no such container it fails with exit 2, not 1.
set -euo pipefail
cd "$(dirname "$0")/.."
c=sp12-t8-dupes-$$
docker=(docker --context default)
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cleanup() { "${docker[@]}" rm -f "$c" >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${docker[@]}" run -d --rm --network none --name "$c" \
  -e POSTGRES_USER=oj -e POSTGRES_PASSWORD=throwaway -e POSTGRES_DB=identitydb postgres:16 >/dev/null
for _ in $(seq 60); do
  # the entrypoint restarts postgres after init; two consecutive answers over the socket mean it is final
  if "${docker[@]}" exec "$c" sh -c 'psql -At -U "$POSTGRES_USER" "$POSTGRES_DB" -c "select 1"' >/dev/null 2>&1; then
    sleep 1
    "${docker[@]}" exec "$c" sh -c 'psql -At -U "$POSTGRES_USER" "$POSTGRES_DB" -c "select 1"' >/dev/null 2>&1 && break
  fi
  sleep 1
done
sql() { "${docker[@]}" exec -i "$c" sh -c 'psql -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"'; }

sql <<'SQL'
CREATE TABLE public.t_users (id uuid PRIMARY KEY, username varchar(255), email varchar(255), google_id varchar(255),
                             status int);
INSERT INTO public.t_users VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Alice', 'alice.one@example.com', NULL, 1),
  ('00000000-0000-0000-0000-00000000000b', 'alice', 'alice.two@example.com', NULL, 0),
  ('00000000-0000-0000-0000-00000000000c', 'bob', 'Bob@X.io', 'g-1', 1),
  ('00000000-0000-0000-0000-00000000000d', 'bobby', 'bob@x.io', 'g-1', 1),
  ('00000000-0000-0000-0000-00000000000e', 'carol', 'carol@example.com', 'g-2', 1),
  ('00000000-0000-0000-0000-00000000000f', 'Carol', 'CAROL@example.com', 'g-2', 2),
  ('00000000-0000-0000-0000-000000000010', NULL, NULL, NULL, 1),
  ('00000000-0000-0000-0000-000000000011', NULL, NULL, NULL, 1);
SQL
run() { IDENTITY_DB_CONTAINER="$c" bash migrations/sp12-dupes.sh 2>&1; }

rc=0; out=$(run) || rc=$?
expected="email bob@x.io 2 00000000-0000-0000-0000-00000000000c 00000000-0000-0000-0000-00000000000d
google_id g-1 2 00000000-0000-0000-0000-00000000000c 00000000-0000-0000-0000-00000000000d
username alice 2 00000000-0000-0000-0000-00000000000a 00000000-0000-0000-0000-00000000000b"
[[ $rc -eq 1 ]] && ok "duplicates exit 1" || bad "duplicates exit 1 (rc=$rc)"
[[ $out == "$expected" ]] && ok "one line per duplicate: <kind> <lowercased value> <count> <ids>" \
  || bad "lines: [$out]"
grep -q 'username alice 2 ' <<< "$out" && ok "Alice and alice are one username" || bad "Alice and alice are one username"
grep -qi 'carol' <<< "$out" && bad "a soft-deleted duplicate is listed" || ok "a soft-deleted duplicate (status 2) is not listed"

# Resolve them: soft-delete one alice, rename and unlink one bob.
sql <<'SQL'
UPDATE public.t_users SET status = 2 WHERE id = '00000000-0000-0000-0000-00000000000b';
UPDATE public.t_users SET email = 'bobby@x.io', google_id = NULL WHERE id = '00000000-0000-0000-0000-00000000000d';
SQL
rc=0; out=$(run) || rc=$?
[[ $rc -eq 0 && $out == "no duplicates" ]] && ok "resolved: prints no duplicates and exits 0" \
  || bad "resolved (rc=$rc): [$out]"

rc=0; out=$(IDENTITY_DB_CONTAINER="$c-absent" bash migrations/sp12-dupes.sh 2>&1) || rc=$?
[[ $rc -eq 2 && $out == *"$c-absent"* ]] && ok "no such container: exit 2, naming it" || bad "no such container (rc=$rc): [$out]"

exit $fail
