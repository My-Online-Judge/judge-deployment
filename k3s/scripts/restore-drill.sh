#!/usr/bin/env bash
# Runs the restore drill (CronJob restore-drill: the latest restic snapshot restored into a throwaway Postgres, row counts compared
# with the counts taken at backup time) and prints its verdict. Exit 0 and only PASS (or INFO) lines means the backup restores.
#   k3s/scripts/restore-drill.sh
# Run it after the first backup, after any change to the backup, and now and then. The drill holds no certificate and no service
# credential: it needs only the repository (the Secret restic, or the claim restic-repo on k3d).
set -euo pipefail
job=drill-$(date +%s)
kubectl -n oj create job "$job" --from=cronjob/restore-drill > /dev/null
trap 'kubectl -n oj delete job "$job" --wait=false > /dev/null 2>&1 || true' EXIT
for _ in $(seq 1 300); do
  status=$(kubectl -n oj get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}')
  [[ $status != / ]] && break
  sleep 3
done
echo "== restore ($job)"
kubectl -n oj logs "job/$job" -c restic-restore 2>&1 | tail -n 5 || true
echo "== verify"
kubectl -n oj logs "job/$job" -c verify 2>&1 || true
[[ ${status:-/} == 1/* ]] || { echo "restore drill FAILED ($job)" >&2; exit 1; }
