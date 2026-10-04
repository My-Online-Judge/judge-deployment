#!/usr/bin/env bash
# Sub-project 2b cutover: copy the problem tables from oj-db into problem-db, keeping every UUID, seed the
# statistics from oj-db's submissions, then prove all of it.
#
# Runs inside a one-shot postgres:16 container (use run-sp2-problem.sh, which supplies):
#   SRC  libpq connection string for oj-db
#   DST  libpq connection string for problem-db (schema already created by problem-service's Flyway)
# Modes: copy (default) = load in one transaction, then verify; verify = only compare.
# Re-runnable: the target tables are emptied first and the whole load is one transaction, so a failed run
# leaves problem-db exactly as it was. Exits non-zero on any count or checksum mismatch.
set -euo pipefail
: "${SRC:?SRC connection string is required}" "${DST:?DST connection string is required}"
MODE=${1:-copy}

# Parents before children (the foreign keys inside problem-db).
TABLES=(t_problems t_problem_tags t_test_cases)

order_key() {
    case $1 in
        t_problem_tags) echo "x.problem_id, x.tag" ;;
        *) echo "x.id" ;;
    esac
}

# problem-db's V1 is authoritative for the column list; oj-db has the same columns.
columns() {
    psql "$DST" -XAtc "SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
                       FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$1'"
}

# "<rows> <md5 of every row, in key order>" — equal on both sides only if every value matches.
fingerprint() {
    psql "$1" -XAtc "SELECT count(*) || ' ' || coalesce(md5(string_agg(x::text, E'\n' ORDER BY $(order_key "$2"))), '-')
                     FROM (SELECT $3 FROM public.$2) x"
}

# Statistics count terminal verdicts only (never PENDING 6 or JUDGING 7), per problem and verdict.
TERMINAL="status NOT IN (6, 7)"
SRC_STATS="SELECT problem_id, status AS verdict, count(*) AS submission_count FROM public.t_submissions
           WHERE $TERMINAL GROUP BY problem_id, status"
SRC_PROCESSED="SELECT id AS submission_id FROM public.t_submissions WHERE $TERMINAL"
stats_fingerprint() {   # $1 connection, $2 query returning (problem_id, verdict, submission_count)
    psql "$1" -XAtc "SELECT count(*) || ' ' || coalesce(sum(submission_count), 0) || ' '
                            || coalesce(md5(string_agg(x::text, E'\n' ORDER BY x.problem_id, x.verdict)), '-')
                     FROM ($2) x"
}
processed_fingerprint() {   # $1 connection, $2 query returning (submission_id)
    psql "$1" -XAtc "SELECT count(*) || ' ' || coalesce(md5(string_agg(x.submission_id::text, E'\n'
                            ORDER BY x.submission_id)), '-') FROM ($2) x"
}

declare -A COLS
for t in "${TABLES[@]}"; do
    COLS[$t]=$(columns "$t")
    [ -n "${COLS[$t]}" ] || { echo "problem-db has no table $t — did problem-service's Flyway run?" >&2; exit 2; }
done

if [ "$MODE" = copy ]; then
    work=$(mktemp -d)
    load=$work/load.sql
    {
        echo '\set ON_ERROR_STOP on'
        echo 'BEGIN;'
        echo "TRUNCATE public.t_processed_verdicts, public.t_problem_stats, $(printf 'public.%s, ' "${TABLES[@]}" | sed 's/, $//');"
    } > "$load"
    for t in "${TABLES[@]}"; do
        psql "$SRC" -Xqc "\\copy (SELECT ${COLS[$t]} FROM public.$t) TO '$work/$t.copy'"
        echo "\\copy public.$t (${COLS[$t]}) FROM '$work/$t.copy'" >> "$load"
    done
    psql "$SRC" -Xqc "\\copy ($SRC_STATS) TO '$work/stats.copy'"
    psql "$SRC" -Xqc "\\copy ($SRC_PROCESSED) TO '$work/processed.copy'"
    {
        echo "\\copy public.t_problem_stats (problem_id, verdict, submission_count) FROM '$work/stats.copy'"
        echo "CREATE TEMP TABLE processed (submission_id uuid) ON COMMIT DROP;"
        echo "\\copy processed FROM '$work/processed.copy'"
        echo "INSERT INTO public.t_processed_verdicts (submission_id, processed_at) SELECT submission_id, now() FROM processed;"
        echo 'COMMIT;'
    } >> "$load"
    psql "$DST" -Xq -f "$load"
elif [ "$MODE" != verify ]; then
    echo "usage: $0 [copy|verify]" >&2
    exit 2
fi

status=0
row() {   # name source target
    local verdict=match
    if [ "$2" != "$3" ]; then verdict=MISMATCH; status=1; fi
    printf '%-22s %-24s %-24s %s\n' "$1" "${2:0:24}" "${3:0:24}" "$verdict"
}
printf '%-22s %-24s %-24s %s\n' table source target checksum
for t in "${TABLES[@]}"; do
    row "$t" "$(fingerprint "$SRC" "$t" "${COLS[$t]}")" "$(fingerprint "$DST" "$t" "${COLS[$t]}")"
done
row t_problem_stats "$(stats_fingerprint "$SRC" "$SRC_STATS")" \
    "$(stats_fingerprint "$DST" "SELECT problem_id, verdict, submission_count FROM public.t_problem_stats")"
row t_processed_verdicts "$(processed_fingerprint "$SRC" "$SRC_PROCESSED")" \
    "$(processed_fingerprint "$DST" "SELECT submission_id FROM public.t_processed_verdicts")"

# The numbers users see: per problem, total and accepted equal a terminal-only version of 2a's JOIN.
users_view() {   # $1 connection, $2 counts query
    psql "$1" -XAtc "SELECT coalesce(md5(string_agg(p.id || ':' || coalesce(c.total, 0) || ':' || coalesce(c.accepted, 0),
                            E'\n' ORDER BY p.id)), '-')
                     FROM public.t_problems p LEFT JOIN ($2) c ON c.problem_id = p.id"
}
row "per-problem totals" \
    "$(users_view "$SRC" "SELECT problem_id, count(*) AS total, count(*) FILTER (WHERE status = 0) AS accepted
                          FROM public.t_submissions WHERE $TERMINAL GROUP BY problem_id")" \
    "$(users_view "$DST" "SELECT problem_id, sum(submission_count) AS total,
                                 coalesce(sum(submission_count) FILTER (WHERE verdict = 0), 0) AS accepted
                          FROM public.t_problem_stats GROUP BY problem_id")"

[ "$status" -eq 0 ] && echo "OK: problems, test cases, tags and statistics copied and verified" \
    || echo "FAILED: see MISMATCH rows above" >&2
exit "$status"
