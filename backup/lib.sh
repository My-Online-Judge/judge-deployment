#!/usr/bin/env bash
# Shared helpers for backup.sh and restore-drill.sh. Source this file; it has no side effects.

# service:table pairs whose row counts are recorded at backup time and re-checked by the drill.
BACKUP_COUNT_TABLES="identity:t_users problem:t_problems problem:t_test_cases submission:t_submissions submission:t_outbox"

# compare_counts <expected.tsv> <actual.tsv>: rows are "name<TAB>count".
# Prints "PASS name n" or "FAIL name expected=e actual=a" (rows missing on either side give an empty value).
# Returns 1 if any row FAILs.
compare_counts() {
  awk -F'\t' '
    NR == FNR { want[$1] = $2; names[$1] = 1; order[++n] = $1; next }
    { got[$1] = $2; if (!($1 in names)) { names[$1] = 1; order[++n] = $1 } }
    END {
      bad = 0
      for (i = 1; i <= n; i++) {
        k = order[i]
        if ((k in want) && (k in got) && want[k] == got[k]) print "PASS " k " " want[k]
        else { print "FAIL " k " expected=" want[k] " actual=" got[k]; bad = 1 }
      }
      exit bad
    }' "$1" "$2"
}
