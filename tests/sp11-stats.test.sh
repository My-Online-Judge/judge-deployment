#!/usr/bin/env bash
# migrations/sp11-last-status.sh and scripts/stats-check.sh against two throwaway postgres:16 containers
# (no network, names from the env vars the scripts read). Fixture tables mirror the real column names.
set -euo pipefail
cd "$(dirname "$0")/.."
export SUBMISSION_DB_CONTAINER=sp11t22-submission-db PROBLEM_DB_CONTAINER=sp11t22-problem-db
docker=(docker --context default)
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cleanup() { "${docker[@]}" stop "$SUBMISSION_DB_CONTAINER" "$PROBLEM_DB_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

for c in "$SUBMISSION_DB_CONTAINER" "$PROBLEM_DB_CONTAINER"; do
  "${docker[@]}" run -d --rm --network none --name "$c" \
    -e POSTGRES_USER=oj -e POSTGRES_PASSWORD=throwaway -e POSTGRES_DB=ojdb postgres:16 >/dev/null
done
sql() { "${docker[@]}" exec -i "$1" sh -c 'psql -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"'; }
for c in "$SUBMISSION_DB_CONTAINER" "$PROBLEM_DB_CONTAINER"; do
  for _ in $(seq 60); do
    # the entrypoint restarts postgres after init; two consecutive answers over the socket mean it is final
    if "${docker[@]}" exec "$c" sh -c 'psql -At -U "$POSTGRES_USER" "$POSTGRES_DB" -c "select 1"' >/dev/null 2>&1; then
      sleep 1
      "${docker[@]}" exec "$c" sh -c 'psql -At -U "$POSTGRES_USER" "$POSTGRES_DB" -c "select 1"' >/dev/null 2>&1 && break
    fi
    sleep 1
  done
done

P1=11111111-1111-1111-1111-111111111111
P2=22222222-2222-2222-2222-222222222222
s() { printf '%s-0000-0000-0000-000000000000' "$(printf '%08d' "$1")"; }
sql "$SUBMISSION_DB_CONTAINER" <<SQL
CREATE TABLE t_submissions (id uuid PRIMARY KEY, status integer NOT NULL, problem_id uuid NOT NULL);
INSERT INTO t_submissions VALUES
 ('$(s 1)', 0, '$P1'), ('$(s 2)', 0, '$P1'), ('$(s 3)', -1, '$P1'),
 ('$(s 4)', 5, '$P2'), ('$(s 5)', -2, '$P2'), ('$(s 6)', 0, '$P2'),
 ('$(s 7)', 6, '$P2'), ('$(s 8)', 7, '$P1');
SQL
sql "$PROBLEM_DB_CONTAINER" <<SQL
CREATE TABLE t_processed_verdicts (submission_id uuid PRIMARY KEY, processed_at timestamp NOT NULL DEFAULT now(), last_status integer NULL);
INSERT INTO t_processed_verdicts (submission_id, last_status) VALUES
 ('$(s 1)', NULL), ('$(s 2)', NULL), ('$(s 3)', NULL), ('$(s 4)', NULL),
 ('$(s 5)', NULL), ('$(s 6)', 0), ('$(s 99)', NULL);
CREATE TABLE t_problem_stats (problem_id uuid NOT NULL, verdict integer NOT NULL, submission_count bigint NOT NULL, PRIMARY KEY (problem_id, verdict));
INSERT INTO t_problem_stats VALUES ('$P1', 0, 2), ('$P1', -1, 1), ('$P2', 5, 1), ('$P2', -2, 1), ('$P2', 0, 1), ('$P2', 4, 0);
SQL
# s6 already has last_status 0 although the submission-db says 0 too; make it differ to prove it is left alone
sql "$PROBLEM_DB_CONTAINER" <<< "UPDATE t_processed_verdicts SET last_status = 3 WHERE submission_id = '$(s 6)';"

out=$(bash migrations/sp11-last-status.sh 2>&1) || true
[[ $out == "backfilled 5 last_status value(s)" ]] && ok "backfill fills the 5 NULL rows with a known status" || bad "backfill first run: [$out]"
left=$(sql "$PROBLEM_DB_CONTAINER" <<< "SELECT count(*) FROM t_processed_verdicts WHERE last_status IS NULL;")
[[ $left == 1 ]] && ok "the row without a submission stays NULL" || bad "NULL rows left: $left"
kept=$(sql "$PROBLEM_DB_CONTAINER" <<< "SELECT last_status FROM t_processed_verdicts WHERE submission_id = '$(s 6)';")
[[ $kept == 3 ]] && ok "a non-NULL last_status is not overwritten" || bad "non-NULL row changed to $kept"
out=$(bash migrations/sp11-last-status.sh 2>&1) || true
[[ $out == "backfilled 0 last_status value(s)" ]] && ok "second run backfills 0" || bad "backfill second run: [$out]"

rc=0; out=$(bash scripts/stats-check.sh 2>&1) || rc=$?
[[ $rc -eq 0 && $out == PASS ]] && ok "stats-check prints PASS" || bad "stats-check PASS (rc=$rc out=[$out])"

sql "$PROBLEM_DB_CONTAINER" <<< "UPDATE t_problem_stats SET submission_count = 3 WHERE problem_id = '$P1' AND verdict = 0;"
rc=0; out=$(bash scripts/stats-check.sh 2>&1) || rc=$?
[[ $rc -eq 1 && $out == "MISMATCH $P1 0 submissions=2 stats=3" ]] && ok "one changed count: exactly one MISMATCH line, exit 1" || bad "stats-check MISMATCH (rc=$rc out=[$out])"

exit $fail
