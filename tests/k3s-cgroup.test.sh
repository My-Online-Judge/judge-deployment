#!/usr/bin/env bash
# ci: skip (needs ../judge-server and its judge-server:test image)
# k3s/components/cgroup (judge-server spec 14.4) against a throw-away K3s in Docker: the real apiserver with k3s/host/admission-config.yaml, the component's
# RuntimeClass and ValidatingAdmissionPolicy, and the Judge Pod of overlays/vps as rendered.
#
#  1. admission: the pod is admitted with the runtime class and its one host path; refused without the class (Pod Security), with another host path, a
#     host namespace, a privileged container, an extra capability or a foreign label (the policy); and the base's pod, without the component, is admitted as before;
#  2. the real sandbox in that pod (the image `judge-server:test` that scripts/sandbox-test.sh builds in ../judge-server, the pod's own spec and probes) with
#     CGROUP_MODE=required: it starts, its startup probe passes, it reports cgroup_isolation=true, and the kubelet made its own directory under the slice,
#     on which the server wrote the limits its pod declares; the same pod without the volume and `required` does not start, with `auto` it starts and says why it runs without.
#
# Needs docker (privileged containers) and ../judge-server's test image; K3S_IMAGE picks the K3s version (default: the newest one this was written for).
# Prints descriptions. Takes a few minutes: the image is loaded into the node's containerd.
set -euo pipefail
cd "$(dirname "$0")/.."
K3S_IMAGE=${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}
SANDBOX_IMAGE=${SANDBOX_TEST_IMAGE:-judge-server:test}
YQ=mikefarah/yq:4.44.3
NAME=oj-k3s-cgtest-$$
tmp=$(mktemp -d)
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cleanup() { docker rm -f -v "$NAME" > /dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

docker image inspect "$SANDBOX_IMAGE" > /dev/null 2>&1 || { echo "no $SANDBOX_IMAGE: run ../judge-server/scripts/sandbox-test.sh once (it builds the test image)" >&2; exit 2; }

kubectl kustomize k3s/overlays/vps > "$tmp/vps.yaml"
docker run --rm -i "$YQ" ea '[.]' -o=json < "$tmp/vps.yaml" > "$tmp/vps.json"
kubectl kustomize k3s/base > "$tmp/base.yaml"
docker run --rm -i "$YQ" ea '[.]' -o=json < "$tmp/base.yaml" > "$tmp/base.json"

echo "== start a throw-away K3s ($K3S_IMAGE)"
docker run -d --name "$NAME" --privileged --cgroupns=host \
  -v "$PWD/k3s/host/admission-config.yaml:/etc/oj-test/admission-config.yaml:ro" \
  "$K3S_IMAGE" server --disable=traefik --disable=servicelb --disable=metrics-server --disable=local-storage \
  --kube-apiserver-arg=admission-control-config-file=/etc/oj-test/admission-config.yaml > /dev/null
k() { docker exec -i "$NAME" kubectl "$@"; }
for _ in $(seq 120); do k get --raw /readyz > /dev/null 2>&1 && break; sleep 2; done
k get --raw /readyz > /dev/null 2>&1 || { docker logs "$NAME" 2>&1 | tail -20; bad "K3s did not come up"; exit 1; }
for _ in $(seq 90); do [[ -n $(k get nodes -o name 2>/dev/null) ]] && break; sleep 2; done # the node object appears a moment after the apiserver is ready
k wait --for=condition=Ready node --all --timeout=180s > /dev/null || { bad "the node is not Ready"; exit 1; }

# the host side of the component: the slice, delegated, as k3s/host/oj-judge.slice makes it under systemd
docker exec "$NAME" sh -c 'echo "+memory +pids +cpu" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; mkdir -p /sys/fs/cgroup/oj-judge.slice \
  && echo "+memory +pids +cpu" > /sys/fs/cgroup/oj-judge.slice/cgroup.subtree_control && cat /sys/fs/cgroup/oj-judge.slice/cgroup.subtree_control' > "$tmp/slice" \
  && grep -q memory "$tmp/slice" && ok "the node has a delegated slice" || { bad "could not make the slice in the throw-away node"; exit 1; }

k create namespace oj > /dev/null
k label namespace oj pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted > /dev/null
jq '.[] | select(.kind=="RuntimeClass" or .kind=="ValidatingAdmissionPolicy" or .kind=="ValidatingAdmissionPolicyBinding")' "$tmp/vps.json" | k apply -f - > /dev/null \
  && ok "the RuntimeClass, the policy and its binding apply" || { bad "the component's cluster objects do not apply"; exit 1; }
sleep 3 # the policy's binding takes a moment to be enforced

pod_of() { # <json file> <deployment> -> a Pod from its template
  jq --arg d "$2" '.[] | select(.kind=="Deployment" and .metadata.name==$d) | {apiVersion:"v1", kind:"Pod",
    metadata:{name:($d+"-test"), namespace:"oj", labels:.spec.template.metadata.labels}, spec:.spec.template.spec}' "$1"
}
admit() { # <description> <expected: ok|reject> <substring of the refusal> ; the pod JSON on stdin
  local out rc=0
  out=$(k apply --dry-run=server -f - 2>&1) || rc=$?
  if [[ $2 == ok ]]; then
    [[ $rc -eq 0 ]] && ok "$1" || { bad "$1: $(echo "$out" | head -3)"; }
  else
    if [[ $rc -ne 0 ]] && grep -qiF -- "$3" <<<"$out"; then ok "$1"; else bad "$1 (want a refusal containing '$3', got rc=$rc: $(echo "$out" | head -2))"; fi
  fi
}

for d in judge run-judge; do
  pod_of "$tmp/vps.json" "$d" > "$tmp/$d.pod.json"
  admit "$d pod: admitted with the runtime class and its one host path" ok "" < "$tmp/$d.pod.json"
  jq 'del(.spec.runtimeClassName)' "$tmp/$d.pod.json" | admit "$d pod: without the runtime class Pod Security still refuses the host path" reject "hostPath" 
  jq '(.spec.volumes[] | select(.name=="oj-cgroup") | .hostPath.path) = "/"' "$tmp/$d.pod.json" | admit "$d pod: another host path is refused by the policy" reject "only host path allowed"
  jq '(.spec.volumes[] | select(.name=="oj-cgroup") | .hostPath.path) = "/sys/fs/cgroup"' "$tmp/$d.pod.json" | admit "$d pod: the whole /sys/fs/cgroup is refused" reject "only host path allowed"
  jq '.spec.hostNetwork = true' "$tmp/$d.pod.json" | admit "$d pod: host network is refused" reject "no host network"
  jq '.spec.hostPID = true' "$tmp/$d.pod.json" | admit "$d pod: host PID is refused" reject "no host network"
  jq '(.spec.initContainers[] | select(.name=="sandbox") | .securityContext) += {privileged: true, allowPrivilegeEscalation: true}' "$tmp/$d.pod.json" | admit "$d pod: a privileged sandbox is refused" reject "no privileged"
  jq '(.spec.initContainers[] | select(.name=="sandbox") | .securityContext.capabilities.add) += ["SYS_ADMIN"]' "$tmp/$d.pod.json" | admit "$d pod: an extra capability is refused" reject "six capabilities"
  jq '.spec.containers[0].ports = [{"containerPort": 80, "hostPort": 80}]' "$tmp/$d.pod.json" | admit "$d pod: a host port is refused" reject "no host ports"
  jq '.metadata.labels.app = "intruder"' "$tmp/$d.pod.json" | admit "$d pod: another workload cannot use the class" reject "may use the judge-delegated"
  pod_of "$tmp/base.json" "$d" | admit "$d pod of the base (no component): baseline-compliant, admitted as before" ok ""
done

echo "== the real sandbox in the Judge Pod ($SANDBOX_IMAGE, CGROUP_MODE=required)"
docker save "$SANDBOX_IMAGE" | docker exec -i "$NAME" /bin/ctr --address /run/k3s/containerd/containerd.sock -n k8s.io images import - > /dev/null
docker run --rm -v "$PWD/../judge-server":/src -v "$tmp":/out -w /src -e GOFLAGS=-mod=mod -e GOCACHE=/tmp/gocache golang:1.24 \
  sh -c 'go run ./internal/testutil/cmd/mktls /out/tls judge-server && chmod -R a+rX /out/tls' > /dev/null
docker cp "$tmp/tls" "$NAME:/tmp/tls" > /dev/null
docker exec "$NAME" kubectl create secret generic tls-judge-server -n oj --from-file=/tmp/tls/tls.crt --from-file=/tmp/tls/tls.key --from-file=/tmp/tls/ca.crt > /dev/null
k create secret generic judge-token -n oj --from-literal=JUDGE_SERVER_TOKEN=t0ken > /dev/null
k create configmap java-policy -n oj --from-literal=java.policy="grant { };" > /dev/null

# The pod as rendered, with this machine's image instead of the registry's, no worker (an idle container instead), and the mode set by the test.
real_pod() { # <name> <mode> <with-cgroup: yes|no>
  jq --arg n "$1" --arg img "$SANDBOX_IMAGE" --arg mode "$2" --arg cg "$3" '
    .metadata.name = $n
    | .spec.containers = [{name:"idle", image:$img, imagePullPolicy:"Never", command:["/usr/bin/tini","--","sleep","infinity"],
        securityContext:{allowPrivilegeEscalation:false, capabilities:{drop:["ALL"]}}}]
    | .spec.initContainers |= map(.image = $img | .imagePullPolicy = "Never")
    | (.spec.initContainers[] | select(.name=="sandbox") | .args) = ["/usr/local/bin/judge-server", "serve"]  # the test image runs the test suite by default
    | (.spec.initContainers[] | select(.name=="sandbox") | .env[] | select(.name=="CGROUP_MODE") | .value) = $mode
    | .spec.volumes |= map(select(.name | startswith("worker-") | not))
    | if $cg == "no" then
        del(.spec.runtimeClassName)
        | .spec.volumes |= map(select(.name != "oj-cgroup"))
        | (.spec.initContainers[] | select(.name=="sandbox") | .volumeMounts) |= map(select(.name != "oj-cgroup"))
        | (.spec.initContainers[] | select(.name=="sandbox") | .env) |= map(select(.name != "POD_NAME" and (.name | startswith("CGROUP_ROOT_") | not)))
      else . end' "$tmp/judge.pod.json"
}
sandbox_log() { k logs -n oj "$1" -c sandbox 2>&1 || true; }
wait_phase() { # <pod> <seconds> <regex of phases to stop at> ; sandbox ready or the pod gone wrong
  for _ in $(seq "$2"); do
    local st
    st=$(k get pod -n oj "$1" -o jsonpath='{.status.initContainerStatuses[?(@.name=="sandbox")].ready}{" "}{.status.initContainerStatuses[?(@.name=="sandbox")].state.waiting.reason}{" "}{.status.initContainerStatuses[?(@.name=="sandbox")].lastState.terminated.exitCode}' 2>/dev/null || true)
    [[ $st =~ $3 ]] && return 0
    sleep 2
  done
  return 1
}

real_pod sandbox-required required yes | k apply -f - > /dev/null
if wait_phase sandbox-required 90 '^true'; then ok "required, with the slice: the sandbox starts and its startup probe passes"
else bad "required, with the slice: the sandbox did not become ready ($(k get pod -n oj sandbox-required -o jsonpath='{.status.initContainerStatuses[*].state}' 2>&1 | head -c 300))"; sandbox_log sandbox-required | tail -5; fi
log=$(sandbox_log sandbox-required)
grep -q "cgroup_isolation=true\|\"cgroup_isolation\":true" <<<"$log" && ok "the server reports cgroup_isolation=true" || { bad "the server does not report cgroup_isolation=true"; echo "$log" | tail -4; }
dir=$(docker exec "$NAME" sh -c 'ls -d /sys/fs/cgroup/oj-judge.slice/*/ 2>/dev/null | head -1')
if [[ -n $dir ]]; then
  mem=$(docker exec "$NAME" cat "${dir}memory.max") ; pids=$(docker exec "$NAME" cat "${dir}pids.max"); cpu=$(docker exec "$NAME" cat "${dir}cpu.max")
  [[ $mem == 1610612736 && $pids == 1024 && $cpu == "200000 100000" ]] && ok "the pod's own directory under the slice carries its declared limits (memory.max $mem, pids.max $pids, cpu.max $cpu)" || bad "the pod's directory has memory.max $mem, pids.max $pids, cpu.max $cpu"
  [[ $(basename "$dir") == sandbox-required ]] && ok "the directory is named for the pod (subPathExpr)" || bad "the directory is $dir, not the pod's name"
else bad "no per-pod directory under the slice"; fi

real_pod sandbox-nocgroup-required required no | k apply -f - > /dev/null
if wait_phase sandbox-nocgroup-required 60 '(CrashLoopBackOff|Error| 1$| 2$)'; then
  sandbox_log sandbox-nocgroup-required | grep -q "CGROUP_MODE=required" && ok "required without the slice: the sandbox refuses to start and names CGROUP_MODE=required, no fallback" || bad "required without the slice failed, but not with the expected message: $(sandbox_log sandbox-nocgroup-required | tail -2)"
else bad "required without the slice: the sandbox did not fail ($(k get pod -n oj sandbox-nocgroup-required -o jsonpath='{.status.initContainerStatuses[*].state}' | head -c 200))"; fi

real_pod sandbox-auto auto no | k apply -f - > /dev/null
if wait_phase sandbox-auto 90 '^true'; then
  l=$(sandbox_log sandbox-auto)
  grep -q "cgroup isolation is off" <<<"$l" && grep -q "cgroup_isolation=false\|\"cgroup_isolation\":false" <<<"$l" && ok "auto without the slice: the sandbox starts, runs without cgroups and says why" || bad "auto without the slice: wrong log: $(echo "$l" | tail -3)"
else bad "auto without the slice: the sandbox did not become ready"; fi

exit $fail
