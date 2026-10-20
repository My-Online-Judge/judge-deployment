#!/usr/bin/env bash
# Shared helpers for backup.sh and restore-drill.sh. Source this file; it has no side effects.

# service:table pairs whose row counts are recorded at backup time and re-checked by the drill.
# shellcheck disable=SC2034  # read by backup.sh and restore-drill.sh, which source this file
BACKUP_COUNT_TABLES="identity:t_users problem:t_problems problem:t_test_cases submission:t_submissions submission:t_outbox"

# Rows listed here are reported as INFO and never fail (they churn constantly on a live system).
BACKUP_INFO_ROWS="t_outbox"

# compare_counts <expected.tsv> <actual.tsv>
# expected rows: "name<TAB>min<TAB>max" (a lone count means min=max); actual rows: "name<TAB>count".
# Prints "PASS name n" or "FAIL name expected=min..max actual=a" (rows missing on either side fail, with an
# empty value), or "INFO ..." for BACKUP_INFO_ROWS. Returns 1 if any row FAILs.
compare_counts() {
  awk -F'\t' -v info="$BACKUP_INFO_ROWS" '
    BEGIN { m = split(info, a, " "); for (j = 1; j <= m; j++) isinfo[a[j]] = 1 }
    NR == FNR { lo[$1] = $2; hi[$1] = ($3 == "" ? $2 : $3); names[$1] = 1; order[++n] = $1; next }
    { got[$1] = $2; if (!($1 in names)) { names[$1] = 1; order[++n] = $1 } }
    END {
      bad = 0
      for (i = 1; i <= n; i++) {
        k = order[i]
        r = (k in lo) ? lo[k] ".." hi[k] : ""
        ok = (k in lo) && (k in got) && got[k] + 0 >= lo[k] + 0 && got[k] + 0 <= hi[k] + 0
        if (k in isinfo) print "INFO " k " expected=" r " actual=" got[k]
        else if (ok) print "PASS " k " " got[k]
        else { print "FAIL " k " expected=" r " actual=" got[k]; bad = 1 }
      }
      exit bad
    }' "$1" "$2"
}
