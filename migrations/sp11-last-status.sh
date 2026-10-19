#!/usr/bin/env bash
# SP11: fill t_processed_verdicts.last_status (problem-db, added by problem-service V5) from the statuses in
# submission-db, so a rejudge can move a submission's count from its old verdict to the new one.
# Run once after problem-service V5 and before any rejudge. Idempotent: only NULL rows are touched, and
# submissions that are PENDING (6) or JUDGING (7) have no verdict to record. Prints a count, nothing else.
set -euo pipefail
SUBMISSION_DB="${SUBMISSION_DB_CONTAINER:-oj-submission-db}"
PROBLEM_DB="${PROBLEM_DB_CONTAINER:-oj-problem-db}"
docker=(docker --context default)

# Unix socket, local trust: the credentials are read inside the containers (as backup/backup.sh does).
# Read fully first, so a failure here cannot leave a half-loaded table to update from.
rows="$("${docker[@]}" exec "$SUBMISSION_DB" sh -c \
  'psql -q -U "$POSTGRES_USER" "$POSTGRES_DB" -c "\copy (SELECT id, status FROM t_submissions WHERE status NOT IN (6, 7)) TO STDOUT"')"

{
  echo 'CREATE TEMP TABLE tmp_submission_status (id uuid PRIMARY KEY, status integer NOT NULL);'
  echo 'COPY tmp_submission_status FROM STDIN;'
  [ -z "$rows" ] || printf '%s\n' "$rows"
  printf '\\.\n'
  echo 'WITH u AS (UPDATE t_processed_verdicts p SET last_status = s.status
                   FROM tmp_submission_status s
                   WHERE p.submission_id = s.id AND p.last_status IS NULL RETURNING 1)
        SELECT count(*) FROM u;'
} | { n="$("${docker[@]}" exec -i "$PROBLEM_DB" sh -c \
        'psql -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"')"; echo "backfilled $n last_status value(s)"; }
