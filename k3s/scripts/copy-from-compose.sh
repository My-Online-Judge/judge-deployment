#!/usr/bin/env bash
# The cutover's data copy: all three databases and the test-case bucket from the compose stack into K3s, exactly (what K3s held
# before is replaced). The K3s services are stopped for the copy and started after it, so nothing writes into a database while it is
# replaced. Run it once as a rehearsal and again at the end, after compose has stopped accepting submissions (README "Cutover from
# compose"): everything written on compose in between is in the second copy, because the second copy is of everything.
#   k3s/scripts/copy-from-compose.sh            copy
#   k3s/scripts/copy-from-compose.sh --dry-run  print the plan, touch nothing
# Each dump streams from the compose container into its K3s pod (never to disk, never with a password on a command line). The bucket
# goes through a directory (docker cp), a kubectl port-forward and the MinIO image's mc, which verifies the certificate against the
# cluster's CA; the credentials reach it as an inherited environment variable. Environment: OJ_COMPOSE_DOCKER (default `docker --context
# default`), OJ_COPY_INSECURE=1 (macOS only: Docker Desktop reaches the port-forward as host.docker.internal, which the certificate does not
# name, so the rehearsal skips the check there).
set -euo pipefail
dry=0
case ${1:-} in --dry-run) dry=1 ;; '') ;; *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;; esac
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
read -r -a docker <<< "${OJ_COMPOSE_DOCKER:-docker --context default}"
services=(identity-service problem-service submission-service api-gateway)
databases=(identity problem submission)
mc_image=$(grep -o 'ghcr.io/my-online-judge/minio:[^ ]*' k3s/base/data/init-jobs.yaml | head -1)

work=''; pf=0
# Whatever stops the script, the K3s services stay stopped: half-copied data must not serve users. Say so, and how to go on.
finish() {
  local rc=$?
  [[ -z $work ]] || rm -rf "$work"
  (( pf == 0 )) || kill "$pf" 2> /dev/null || true
  if (( rc != 0 && dry == 0 )); then
    echo "copy-from-compose.sh: FAILED (exit $rc). The K3s services are STOPPED and the data may be half copied: fix the cause and run it again (a run replaces everything), it starts the services at the end." >&2
  fi
}
trap finish EXIT
say() { printf '== %s\n' "$*"; }
run() { if (( dry )); then printf '+ %s\n' "$*"; else "$@"; fi; }

say "stop the K3s services"
run kubectl -n oj scale "deploy/${services[0]}" "deploy/${services[1]}" "deploy/${services[2]}" "deploy/${services[3]}" --replicas=0
for s in "${services[@]}"; do run kubectl -n oj wait --for=delete pod -l "app=$s" --timeout=120s; done

for db in "${databases[@]}"; do
  say "copy $db-db"
  if (( dry )); then
    echo "+ ${docker[*]} exec oj-$db-db pg_dump -Fc --no-owner | kubectl -n oj exec -i $db-db-0 -- pg_restore --clean --if-exists --no-owner --exit-on-error"
  else
    "${docker[@]}" exec "oj-$db-db" sh -c 'pg_dump -Fc --no-owner -U "$POSTGRES_USER" "$POSTGRES_DB"' \
      | kubectl -n oj exec -i "$db-db-0" -- sh -c 'pg_restore --clean --if-exists --no-owner --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
  fi
done

say "copy the test-case bucket"
if (( dry )); then
  echo "+ ${docker[*]} exec oj-minio mc mirror local/<bucket> /tmp/oj-copy; docker cp; kubectl port-forward svc/minio 19000:9000"
  echo "+ docker run --rm --entrypoint mc -e MC_HOST_k3s <minio image> mirror --overwrite --remove /in k3s/<bucket>"
else
  work=$(mktemp -d)
  bucket=$(kubectl -n oj get secret minio-init -o jsonpath='{.data.MINIO_BUCKET}' | base64 -d)
  "${docker[@]}" exec -e BUCKET="$bucket" oj-minio sh -c 'rm -rf /tmp/oj-copy && SSL_CERT_FILE=/etc/oj/tls/ca.crt MC_HOST_local="https://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@localhost:9000" mc mirror --overwrite "local/$BUCKET" /tmp/oj-copy' > /dev/null
  "${docker[@]}" cp oj-minio:/tmp/oj-copy "$work/in"
  "${docker[@]}" exec oj-minio rm -rf /tmp/oj-copy
  kubectl -n oj get secret tls-minio -o jsonpath='{.data.ca\.crt}' | base64 -d > "$work/ca.crt"
  kubectl -n oj port-forward svc/minio 19000:9000 > /dev/null 2>&1 & pf=$!
  sleep 4
  MC_HOST_k3s="https://$(kubectl -n oj get secret minio-root -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d):$(kubectl -n oj get secret minio-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)@localhost:19000"
  net=(--network host -v "$work/ca.crt:/ca.crt:ro" -e SSL_CERT_FILE=/ca.crt); mc_flags=()
  if [[ $(uname) == Darwin ]]; then
    [[ ${OJ_COPY_INSECURE:-} == 1 ]] || { echo "copy-from-compose.sh: on macOS the port-forward is reached as host.docker.internal, which MinIO's certificate does not name; set OJ_COPY_INSECURE=1 for a rehearsal" >&2; exit 1; }
    MC_HOST_k3s=${MC_HOST_k3s/localhost:19000/host.docker.internal:19000}; net=(); mc_flags=(--insecure)
  fi
  export MC_HOST_k3s
  "${docker[@]}" run --rm --entrypoint mc ${net[@]+"${net[@]}"} -e MC_HOST_k3s -v "$work/in:/in:ro" "$mc_image" ${mc_flags[@]+"${mc_flags[@]}"} mirror --overwrite --remove /in "k3s/$bucket"
fi

say "start the K3s services"
run kubectl -n oj scale "deploy/${services[0]}" "deploy/${services[1]}" "deploy/${services[2]}" "deploy/${services[3]}" --replicas=1
for s in "${services[@]}"; do run kubectl -n oj rollout status "deploy/$s" --timeout=300s; done
say "done: compare with k3s/scripts/restore-drill.sh's row counts, or psql both sides"
