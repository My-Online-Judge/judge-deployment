#!/usr/bin/env bash
# Sub-project 3b cutover: copy the submission tables from oj-db into submission-db, keeping every UUID, then prove
# the copy with per-table row counts and full-row checksums.
#
# Runs inside a one-shot postgres:16 container (use run-sp3-submission.sh, which supplies):
#   SRC  libpq connection string for oj-db
#   DST  libpq connection string for submission-db (schema already created by sp3-flyway.sh)
# Modes: copy (default) = load in one transaction, then verify; verify = only compare.
# Every outbox row is copied, published ones too: the stuck-submission query reads an outbox row's published_at.
# Re-runnable before the go-live: the target tables are emptied first and the whole load is one transaction, so a
# failed run leaves submission-db exactly as it was. After the go-live oj-db is stale, so copy refuses when
# submission-db holds a submission or an outbox row that oj-db does not (FORCE=1 overrides). Exits non-zero on any
# count or checksum mismatch.
set -euo pipefail
: "${SRC:?SRC connection string is required}" "${DST:?DST connection string is required}"
MODE=${1:-copy}

# Parents before children (t_submissions references t_languages).
TABLES=(t_languages t_judge_servers t_submissions t_outbox)

# submission-db's V1 is authoritative for the column list; oj-db has the same columns.
columns() {
    psql "$DST" -XAtc "SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
                       FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$1'"
}

# "<rows> <md5 of every row, in id order>" — equal on both sides only if every value matches.
fingerprint() {
    psql "$1" -XAtc "SELECT count(*) || ' ' || coalesce(md5(string_agg(x::text, E'\n' ORDER BY x.id)), '-')
                     FROM (SELECT $3 FROM public.$2) x"
}

# How far submission-db is ahead of oj-db: "<submissions> <outbox rows>" it holds that oj-db does not.
ahead_of_source() {
    local work=$1
    psql "$DST" -Xqc "\\copy (SELECT id FROM public.t_submissions) TO '$work/dst-submissions.copy'"
    psql "$DST" -Xqc "\\copy (SELECT id FROM public.t_outbox) TO '$work/dst-outbox.copy'"
    psql "$SRC" -XqAt -v ON_ERROR_STOP=1 <<SQL
CREATE TEMP TABLE dst_submissions (id uuid);
\\copy dst_submissions FROM '$work/dst-submissions.copy'
CREATE TEMP TABLE dst_outbox (id uuid);
\\copy dst_outbox FROM '$work/dst-outbox.copy'
SELECT (SELECT count(*) FROM dst_submissions d WHERE NOT EXISTS (SELECT 1 FROM public.t_submissions s WHERE s.id = d.id))
       || ' ' || (SELECT count(*) FROM dst_outbox d WHERE NOT EXISTS (SELECT 1 FROM public.t_outbox s WHERE s.id = d.id));
SQL
}

declare -A COLS
for t in "${TABLES[@]}"; do
    COLS[$t]=$(columns "$t")
    [ -n "${COLS[$t]}" ] || { echo "submission-db has no table $t — did sp3-flyway.sh run?" >&2; exit 2; }
done

if [ "$MODE" = copy ]; then
    work=$(mktemp -d)
    if [ "${FORCE:-}" != 1 ]; then
        read -r new_submissions new_outbox <<< "$(ahead_of_source "$work")"
        if [ "$new_submissions" != 0 ] || [ "$new_outbox" != 0 ]; then
            echo "REFUSED: submission-db holds $new_submissions submissions and $new_outbox outbox rows that oj-db does" \
                 "not — it has moved on since the cutover, and a copy would replace them with oj-db's stale tables." \
                 "Nothing was changed. FORCE=1 overrides." >&2
            exit 3
        fi
    fi
    load=$work/load.sql
    {
        echo '\set ON_ERROR_STOP on'
        echo 'BEGIN;'
        echo "TRUNCATE $(printf 'public.%s, ' "${TABLES[@]}" | sed 's/, $//');"
    } > "$load"
    for t in "${TABLES[@]}"; do
        psql "$SRC" -Xqc "\\copy (SELECT ${COLS[$t]} FROM public.$t) TO '$work/$t.copy'"
        echo "\\copy public.$t (${COLS[$t]}) FROM '$work/$t.copy'" >> "$load"
    done
    echo 'COMMIT;' >> "$load"
    psql "$DST" -Xq -f "$load"
elif [ "$MODE" != verify ]; then
    echo "usage: $0 [copy|verify]" >&2
    exit 2
fi

status=0
printf '%-18s %-24s %-24s %s\n' table source target checksum
for t in "${TABLES[@]}"; do
    src=$(fingerprint "$SRC" "$t" "${COLS[$t]}")
    dst=$(fingerprint "$DST" "$t" "${COLS[$t]}")
    verdict=match
    if [ "$src" != "$dst" ]; then verdict=MISMATCH; status=1; fi
    printf '%-18s %-24s %-24s %s\n' "$t" "${src:0:24}" "${dst:0:24}" "$verdict"
done
[ "$status" -eq 0 ] && echo "OK: languages, judge servers, submissions and the outbox copied and verified" \
    || echo "FAILED: see MISMATCH rows above" >&2
exit "$status"
