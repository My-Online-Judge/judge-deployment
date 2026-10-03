#!/usr/bin/env bash
# Sub-project 2a: test cases whose files exist neither in their problem's CURRENT bundle nor in the
# judge-api jar ("orphans"). They are not judged today; the backfill reports them and never deletes.
#
#   migrations/sp2a-orphans.sh            list the orphans the last backfill reported
#   migrations/sp2a-orphans.sh delete ID… delete exactly these t_test_cases rows (one transaction)
#
# Deleting is the operator's decision: pass the ids the list printed, after checking them.
set -euo pipefail
case "${1:-list}" in
  list)
    docker logs "${API_CONTAINER:-oj-judge-api}" 2>&1 | grep -o 'ORPHAN test case id=[^ ]* problem=[^ ]* input=[^:]*' | sort -u \
      || echo "no orphans reported"
    ;;
  delete)
    shift
    [ "$#" -gt 0 ] || { echo "usage: $0 delete <test case id>..." >&2; exit 2; }
    ids=""
    for id in "$@"; do
      [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || { echo "not a test case id: $id" >&2; exit 2; }
      ids="$ids${ids:+,}'$id'"
    done
    docker exec -i "${DB_CONTAINER:-oj-db}" sh -c 'psql -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<SQL
BEGIN;
DELETE FROM t_test_cases WHERE id IN ($ids) RETURNING 'deleted ' || id;
COMMIT;
SQL
    ;;
  *)
    echo "usage: $0 [list | delete <test case id>...]" >&2
    exit 2
    ;;
esac
