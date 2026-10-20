#!/usr/bin/env bash
# Lists the processes that run as root in a compose project's running containers (sp12 task 13).
# Usage: scripts/nonroot-audit.sh [project]      (default judge-deployment)
# NONROOT_ALLOW: services that may run as root (default: the sandboxes, the edge, minio, cadvisor and node-exporter).
# Prints `ROOT <service> <comm>` per root process and exits 1; otherwise prints PASS.
set -uo pipefail
project=${1:-judge-deployment}
allow=${NONROOT_ALLOW:-judge-server judge-server-2 edge minio cadvisor node-exporter}
found=0
while read -r id; do
  [[ -n $id ]] || continue
  service=$(docker --context default inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id")
  [[ " $allow " == *" $service "* ]] && continue
  while read -r _ uid comm; do
    if [[ $uid == 0 ]]; then echo "ROOT $service $comm"; found=1; fi
  done < <(docker --context default top "$id" -eo pid,uid,comm | tail -n +2)
done < <(docker --context default ps -q --filter "label=com.docker.compose.project=$project")
if [[ $found == 1 ]]; then exit 1; fi
echo PASS
