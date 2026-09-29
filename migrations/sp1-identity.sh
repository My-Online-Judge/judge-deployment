#!/usr/bin/env bash
# Sub-project 1b cutover: copy the eight identity tables from oj-db into identity-db, keeping every
# UUID, then prove the copy with per-table row counts and full-row checksums.
#
# Runs inside a one-shot postgres:16 container (use run-sp1-identity.sh, which supplies):
#   SRC  libpq connection string for oj-db
#   DST  libpq connection string for identity-db (schema already created by identity-service's Flyway)
# Re-runnable: the target tables are emptied first and the whole load is one transaction, so a failed
# run leaves identity-db exactly as it was. Exits non-zero on any count or checksum mismatch.
set -euo pipefail
: "${SRC:?SRC connection string is required}" "${DST:?DST connection string is required}"

# Parents before children (the foreign keys inside identity-db).
TABLES=(t_permissions t_roles t_roles_permissions t_users t_users_roles t_tokens t_login_attempts t_access_bans)

order_key() {
    case $1 in
        t_roles_permissions) echo "x.role_id, x.permission_id" ;;
        t_users_roles) echo "x.user_id, x.role_id" ;;
        *) echo "x.id" ;;
    esac
}

# identity-db's V1 is authoritative for the column list; oj-db has the same columns.
columns() {
    psql "$DST" -XAtc "SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
                       FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$1'"
}

# "<rows> <md5 of every row, in key order>" — equal on both sides only if every value matches.
fingerprint() {
    psql "$1" -XAtc "SELECT count(*) || ' ' || coalesce(md5(string_agg(x::text, E'\n' ORDER BY $(order_key "$2"))), '-')
                     FROM (SELECT $3 FROM public.$2) x"
}

work=$(mktemp -d)
load=$work/load.sql
{
    echo '\set ON_ERROR_STOP on'
    echo 'BEGIN;'
    echo "TRUNCATE $(printf 'public.%s, ' "${TABLES[@]}" | sed 's/, $//');"
} > "$load"
declare -A COLS
for t in "${TABLES[@]}"; do
    COLS[$t]=$(columns "$t")
    [ -n "${COLS[$t]}" ] || { echo "identity-db has no table $t — did identity-service's Flyway run?" >&2; exit 2; }
    psql "$SRC" -Xqc "\\copy (SELECT ${COLS[$t]} FROM public.$t) TO '$work/$t.copy'"
    echo "\\copy public.$t (${COLS[$t]}) FROM '$work/$t.copy'" >> "$load"
done
echo 'COMMIT;' >> "$load"
psql "$DST" -Xq -f "$load"

status=0
printf '%-22s %10s %10s  %s\n' table source target checksum
for t in "${TABLES[@]}"; do
    read -r src_rows src_sum <<< "$(fingerprint "$SRC" "$t" "${COLS[$t]}")"
    read -r dst_rows dst_sum <<< "$(fingerprint "$DST" "$t" "${COLS[$t]}")"
    verdict=match
    if [ "$src_rows" != "$dst_rows" ] || [ "$src_sum" != "$dst_sum" ]; then
        verdict=MISMATCH
        status=1
    fi
    printf '%-22s %10s %10s  %s\n' "$t" "$src_rows" "$dst_rows" "$verdict"
done
[ "$status" -eq 0 ] && echo "OK: all ${#TABLES[@]} tables copied and verified" || echo "FAILED: see MISMATCH rows above" >&2
exit "$status"
