#!/usr/bin/env bash
# SP11: compare per-problem verdict counts in submission-db (t_submissions) with problem-db (t_problem_stats).
# PENDING (6) and JUDGING (7) have no verdict, so they are not counted by problem-service and are left out here;
# every terminal status (SYSTEM_ERROR 5 and COMPILE_ERROR -2 included) is counted, so none is excluded.
# Prints PASS, or one MISMATCH line per difference and exits 1. Counts only. Rows in flight (a verdict not yet
# consumed) can show up as a transient mismatch; run again after the consumer lag is 0.
set -euo pipefail
SUBMISSION_DB="${SUBMISSION_DB_CONTAINER:-oj-submission-db}"
PROBLEM_DB="${PROBLEM_DB_CONTAINER:-oj-problem-db}"
docker=(docker --context default)
psql_in() { # <container> <sql>; Unix socket, credentials read inside the container
  "${docker[@]}" exec "$1" sh -c 'psql -q -At -F " " -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB" -c "$1"' sh "$2"
}
a="$(psql_in "$SUBMISSION_DB" 'SELECT problem_id, status, count(*) FROM t_submissions WHERE status NOT IN (6, 7) GROUP BY 1, 2')"
b="$(psql_in "$PROBLEM_DB" 'SELECT problem_id, verdict, submission_count FROM t_problem_stats WHERE submission_count > 0')"

out="$(awk '
  FNR == NR { if (NF) { k = $1 " " $2; A[k] = $3; K[k] = 1 } next }
  NF { k = $1 " " $2; B[k] = $3; K[k] = 1 }
  END { for (k in K) { x = (k in A) ? A[k] : 0; y = (k in B) ? B[k] : 0
          if (x != y) printf "MISMATCH %s submissions=%s stats=%s\n", k, x, y } }
' <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sort)"
if [ -z "$out" ]; then echo PASS; else echo "$out"; exit 1; fi
