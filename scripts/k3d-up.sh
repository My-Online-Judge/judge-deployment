#!/usr/bin/env bash
# A K3s cluster in Docker (k3d) for trying k3s/ on a laptop.
#   scripts/k3d-up.sh up        create the cluster `oj`; Traefik answers on https://localhost:18443 and http://localhost:18080
#   scripts/k3d-up.sh import    load the locally built images into it (scripts/local-stack.sh build makes them)
#   scripts/k3d-up.sh down      delete the cluster
# 18443/18080, not 443/80, so the compose stack (scripts/local-stack.sh) can run beside it, and not 8443/8080, which other
# dev stacks commonly hold.
# The node limits every pod to 2048 processes (compose gave the sandbox pids_limit 1024; a pod's limit is the kubelet's, so on
# the server install K3s with --kubelet-arg=pod-max-pids=2048 too).
# Environment: K3D_HTTPS_PORT, K3D_HTTP_PORT (the host ports), K3D_MEMORY (the node's memory limit, default 10g),
# K3S_IMAGE (default the version below).
set -euo pipefail

cluster=oj
k3s_image=${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}
memory=${K3D_MEMORY:-10g}
https_port=${K3D_HTTPS_PORT:-18443}
http_port=${K3D_HTTP_PORT:-18080}

die() { echo "k3d-up.sh: $*" >&2; exit 1; }
command -v k3d > /dev/null || die "k3d is not installed (macOS: brew install k3d)"

# check_port <port>: a port another container or a process holds would roll the whole cluster creation back
check_port() {
  local port=$1 owners pid
  owners=$(docker ps --filter "publish=$port" --format '{{.Names}}' | tr '\n' ' ')
  [[ -z $owners ]] || die "host port $port is published by the container(s) $owners: set K3D_HTTPS_PORT / K3D_HTTP_PORT"
  if command -v lsof > /dev/null; then
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2> /dev/null | head -1 || true)
    [[ -z $pid ]] || die "host port $port is held by process $pid ($(ps -o comm= -p "$pid" 2> /dev/null || echo '?')): set K3D_HTTPS_PORT / K3D_HTTP_PORT"
  fi
}

case ${1:-} in
  up)
    if k3d cluster list "$cluster" > /dev/null 2>&1; then
      echo "the cluster $cluster exists"
    else
      check_port "$https_port"
      check_port "$http_port"
      k3d cluster create "$cluster" --image "$k3s_image" --agents 0 --servers-memory "$memory" \
        -p "$https_port:443@loadbalancer" -p "$http_port:80@loadbalancer" \
        --k3s-arg "--kubelet-arg=pod-max-pids=2048@server:0" --wait
    fi
    kubectl config use-context "k3d-$cluster" > /dev/null
    kubectl get nodes
    ;;
  import)
    # `docker images` prints Docker Hub names without the docker.io/ prefix; ghcr.io/my-online-judge/ is the MinIO image only
    images=()
    while IFS= read -r image; do images+=("$image"); done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(thanhtuanle/|ghcr.io/my-online-judge/|mock-judge-server:)' | sort -u)
    ((${#images[@]} > 0)) || die "no image to import: run scripts/local-stack.sh build first"
    k3d image import --cluster "$cluster" "${images[@]}"
    ;;
  down)
    k3d cluster delete "$cluster"
    ;;
  *)
    echo "usage: $0 up|import|down" >&2
    exit 2
    ;;
esac
