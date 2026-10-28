#!/usr/bin/env bash
# Runs the whole stack on one machine (a laptop with Docker Desktop), with the mock sandboxes.
#
#   scripts/local-stack.sh doctor   what is missing, without changing anything
#   scripts/local-stack.sh init     .env* files with random secrets, and the private CA with every certificate
#   scripts/local-stack.sh build    the images from the sibling checkouts, one at a time
#   scripts/local-stack.sh up       start the stack and wait until it is healthy
#   scripts/local-stack.sh smoke    log in, create a problem, submit, run: the stack answers end to end
#   scripts/local-stack.sh status   containers and their memory
#   scripts/local-stack.sh down [--volumes]   stop it; --volumes also deletes the databases and every upload
#
# https://localhost is the portal and the API (`pki/out/ca/ca.crt` is the CA to trust); the root admin is `admin`.
# Without observability: Prometheus, Grafana, Alertmanager and the exporters read the Linux host and run on a server.
# `init` keeps what exists, so it is safe to run again. Nothing here edits a tracked file.
#
# Environment: OJ_ROOT (the directory that holds the sibling repos, default: the parent of judge-deployment),
# DOCKER_CONTEXT (as docker's own), LOCAL_JRE_IMAGE (arm64 only, see `build`).
set -euo pipefail

# pki.sh and this script need bash >= 4; macOS ships 3.2. Run again under Homebrew's bash when there is one.
if ((BASH_VERSINFO[0] < 4)); then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x $candidate ]] && exec "$candidate" "$0" "$@"
  done
  echo "local-stack.sh: needs bash >= 4 (macOS: brew install bash)" >&2
  exit 1
fi

dep=${OJ_DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}   # OJ_DEPLOY_DIR: for tests
root=${OJ_ROOT:-$(dirname "$dep")}
cd "$dep"

compose=(docker compose -f docker-compose.yml -f docker-compose.mock.yml -f docker-compose.local.yml)
# The stack minus prometheus, alertmanager, grafana, cadvisor, node-exporter and the db/redis/kafka exporters.
services=(edge judge-portal api-gateway identity-service problem-service submission-service
  judge-worker run-worker judge-server judge-server-2 jaeger)
java_services=(identity-service problem-service submission-service api-gateway)
ca=pki/out/ca/ca.crt

die() { echo "local-stack.sh: $*" >&2; exit 1; }
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# ---- env files -------------------------------------------------------------------------------------------------------

cmd_env() {
  python3 - "$dep" <<'PY'
import base64, os, re, secrets, subprocess, sys, tempfile
os.chdir(sys.argv[1])
rand = lambda: secrets.token_hex(24)

def make(name, replacements):
    if os.path.exists(name):
        print(f"kept    {name}")
        return
    text = open(name + ".example").read()
    for pattern, value in replacements:
        text, n = re.subn(pattern, lambda m: m.group(1) + value, text, flags=re.M)
        if n == 0:
            sys.exit(f"{name}: no line matches {pattern}")
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)   # never readable by others, not even briefly
    with os.fdopen(fd, "w") as f:
        f.write(text)
    print(f"created {name}")

db = {n: rand() for n in ("identity", "problem", "submission")}
make(".env", [(r"^(JUDGE_SERVER_TOKEN=).*$", rand()), (r"^(MINIO_ROOT_PASSWORD=).*$", rand()),
              (r"^(MINIO_PROBLEM_SECRET_KEY=).*$", rand()), (r"^(MINIO_WORKER_SECRET_KEY=).*$", rand()),
              (r"^(PG_MONITOR_PASSWORD=).*$", rand()), (r"^(GRAFANA_ADMIN_PASSWORD=).*$", rand())])
make(".env.identity-db", [(r"^(POSTGRES_PASSWORD=).*$", db["identity"])])
if os.path.exists(".env.identity"):
    keys = None
else:
    d = tempfile.mkdtemp()
    try:
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                        "-out", f"{d}/k.pem"], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", f"{d}/k.pem", "-pubout", "-out", f"{d}/p.pem"],
                       check=True, capture_output=True)
        b64 = lambda p: base64.b64encode(open(p, "rb").read()).decode()
        keys = (b64(f"{d}/k.pem"), b64(f"{d}/p.pem"))
    finally:
        for f in ("k.pem", "p.pem"):
            if os.path.exists(f"{d}/{f}"):
                os.remove(f"{d}/{f}")
        os.rmdir(d)
make(".env.identity", [(r"^(POSTGRES_PASSWORD=).*$", db["identity"]), (r"^(DATABASE_PASSWORD=).*$", db["identity"])]
     + ([(r"^(JWT_RSA_PRIVATE_KEY=).*$", keys[0]), (r"^(JWT_RSA_PUBLIC_KEY=).*$", keys[1])] if keys else []))
make(".env.problem", [(r"^(POSTGRES_PASSWORD=).*$", db["problem"]), (r"^(DATABASE_PASSWORD=).*$", db["problem"])])
make(".env.submission", [(r"^(POSTGRES_PASSWORD=).*$", db["submission"]), (r"^(DATABASE_PASSWORD=).*$", db["submission"])])
PY
}

# ---- certificates ----------------------------------------------------------------------------------------------------

cmd_pki() {
  local id missing=0
  [[ -f $ca ]] || missing=1
  while read -r id _; do
    case $id in '' | '#'* | rogue) continue ;; esac
    [[ -f pki/out/$id/tls.crt ]] || missing=1
  done < pki/identities.txt
  if ((missing == 0)); then
    echo "kept    pki/out"
    return
  fi
  [[ -f $ca ]] || "$BASH" pki/pki.sh init-ca
  "$BASH" pki/pki.sh issue-all > /dev/null
  echo "created pki/out (every certificate was issued by the CA)"
}

cmd_init() {
  cmd_env
  cmd_pki
  scripts/preflight.sh
}

# ---- checks ----------------------------------------------------------------------------------------------------------

oj_common_version() { # oj_common_version <pom>: the version of the oj-common dependency, or of oj-common itself
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
dep = re.search(r"<artifactId>oj-common</artifactId>\s*<version>([^<]+)</version>", text)
print(dep.group(1) if dep else re.search(r"<version>([^<]+)</version>", text[text.index("<artifactId>oj-common"):]).group(1))
PY
}

# Each Java Dockerfile compiles the sibling oj-common checkout and the service's pom needs exactly that version.
check_pins() {
  local svc repo want have
  have=$(oj_common_version "$root/oj-common/pom.xml")
  for svc in "${java_services[@]}"; do
    repo=oj-$svc
    [[ -f $root/$repo/pom.xml ]] || continue
    want=$(oj_common_version "$root/$repo/pom.xml")
    if [[ $want == "$have" ]]; then ok "$repo pins oj-common $want, the version of the checkout"
    else bad "$repo pins oj-common $want but $root/oj-common is $have: its image cannot be built"; fi
  done
}

# published_ports: every host port the stack publishes (the services above and what they depend on), one per line
published_ports() {
  "${compose[@]}" config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)["services"]
todo, started = list(sys.argv[1:]), set()
while todo:
    name = todo.pop()
    if name not in started and name in config:
        started.add(name)
        todo.extend(config[name].get("depends_on") or {})
ports = {int(p["published"]) for name in started for p in config[name].get("ports", []) if p.get("published")}
print("\n".join(str(p) for p in sorted(ports)))' "${services[@]}"
}

# check_ports: a port another container or a process holds would make `up` fail half way
check_ports() {
  local port owners others pid
  while read -r port; do
    [[ -n $port ]] || continue
    owners=$(docker ps --filter "publish=$port" --format '{{.Names}}')
    others=$(grep -vE '^(oj-|judge-deployment-)' <<< "$owners" || true)
    if [[ -n $others ]]; then bad "port $port is published by another container: $(tr '\n' ' ' <<< "$others")"; continue; fi
    if [[ -z $owners ]] && command -v lsof > /dev/null; then
      pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2> /dev/null | head -1 || true)
      if [[ -n $pid ]]; then bad "port $port is held by process $pid ($(ps -o comm= -p "$pid" 2> /dev/null || echo '?'))"; continue; fi
    fi
    ok "port $port is free or ours"
  done < <(published_ports)
}

cmd_doctor() {
  local tool
  for tool in python3 openssl curl docker; do
    if command -v "$tool" > /dev/null; then ok "$tool"; else bad "$tool is not installed"; fi
  done
  if docker info > /dev/null 2>&1; then ok "docker answers (context $(docker context show))"; else bad "docker does not answer: start Docker Desktop, or set DOCKER_CONTEXT"; fi
  if scripts/preflight.sh > /dev/null; then ok "the sibling repos are on main and clean (scripts/preflight.sh)"; else bad "scripts/preflight.sh fails: run it to see which repo"; fi
  check_pins
  if docker info > /dev/null 2>&1; then check_ports; fi
  exit "$fail"
}

# ---- build -----------------------------------------------------------------------------------------------------------

# service_build <service>: "<image> <context> <name=path>..." from the resolved compose file
service_build() {
  "${compose[@]}" config --format json | python3 -c '
import json, sys
s = json.load(sys.stdin)["services"][sys.argv[1]]
b = s["build"]
print(s["image"], b["context"], *[f"{k}={v}" for k, v in (b.get("additional_contexts") or {}).items()])' "$1"
}

cmd_build() {
  local svc line image context arch pair
  local -a args extras fields
  check_pins
  ((fail == 0)) || exit 1
  arch=$(uname -m)
  for svc in "${java_services[@]}"; do
    echo "== build $svc"
    if [[ $arch == arm64 || $arch == aarch64 ]]; then
      # The runtime stage of these images is eclipse-temurin:17-jre-alpine, which has no arm64 variant. buildx replaces
      # that FROM with an alpine JRE 17 that has one (the Dockerfiles are untouched; the tag is the one compose runs, so
      # `up` finds it). A different JRE vendor than the servers': good for trying the stack, not a release build.
      line=$(service_build "$svc")
      read -ra fields <<< "$line"
      image=${fields[0]}
      context=${fields[1]}
      extras=("${fields[@]:2}")
      args=(--build-context "eclipse-temurin:17-jre-alpine=docker-image://${LOCAL_JRE_IMAGE:-bellsoft/liberica-openjre-alpine:17}")
      for pair in "${extras[@]}"; do args+=(--build-context "$pair"); done
      docker buildx build --load -t "$image" "${args[@]}" "$context"
    else
      "${compose[@]}" build "$svc"
    fi
  done
  for svc in judge-worker judge-portal judge-server; do
    echo "== build $svc"
    "${compose[@]}" build "$svc"
  done
}

# ---- up, status, down ------------------------------------------------------------------------------------------------

cmd_up() {
  scripts/preflight.sh > /dev/null || die "scripts/preflight.sh fails (a sibling repo is off main or dirty): run it to see which"
  check_ports
  ((fail == 0)) || die "a port the stack publishes is taken (above); stop what holds it"
  "${compose[@]}" up -d --no-build "${services[@]}"
  echo "waiting for the containers to be healthy (up to 5 minutes)"
  local i state
  for ((i = 0; i < 30; i++)); do
    state=$(docker ps --filter name='^oj-' --format '{{.Names}} {{.Status}}')
    if ! grep -qE 'health: starting|unhealthy' <<< "$state"; then break; fi
    sleep 10
  done
  if grep -qE 'health: starting|unhealthy' <<< "$state"; then
    grep -E 'health: starting|unhealthy' <<< "$state" >&2
    die "not healthy yet: docker logs <name>"
  fi
  echo "up: https://localhost (trust $dep/$ca); run: scripts/local-stack.sh smoke"
}

cmd_status() {
  "${compose[@]}" ps --format 'table {{.Name}}\t{{.Status}}'
  local -a names
  mapfile -t names < <(docker ps --filter name='^oj-' --filter name='^judge-deployment-' --format '{{.Names}}')
  docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' "${names[@]}"
}

cmd_down() {
  case ${1:-} in
    '') "${compose[@]}" down ;;
    --volumes)
      echo "this deletes the databases, the MinIO uploads and every other volume of the stack"
      "${compose[@]}" down -v
      ;;
    *) die "usage: down [--volumes]" ;;
  esac
}

# ---- smoke -----------------------------------------------------------------------------------------------------------

cmd_smoke() {
  local base=https://localhost tmp pass slug=smoke-a-plus-b id status i code
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  pass=$(grep '^OJ_ADMIN_PASSWORD=' .env 2> /dev/null | cut -d= -f2- || true)
  pass=${pass:-Admin@12345}   # the root admin identity's V2 migration seeds; change it, then set OJ_ADMIN_PASSWORD in .env
  api() { curl -sS --cacert "$ca" -b "$tmp/jar" -c "$tmp/jar" "$@"; }

  code=$(curl -sS --cacert "$ca" "$base/api/v1/languages" -o "$tmp/langs" -w '%{http_code}')
  if [[ $code == 200 ]] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["data"] else 1)' "$tmp/langs"; then ok "the languages come back through the edge"; else bad "languages: HTTP $code"; fi
  if curl -sSI --cacert "$ca" "$base/" | grep -qi '^content-security-policy:'; then ok "the portal is served with its Content-Security-Policy"; else bad "no Content-Security-Policy on the portal"; fi

  code=$(api -H 'Content-Type: application/json' -d "$(python3 -c 'import json,sys; print(json.dumps({"username": "admin", "password": sys.argv[1]}))' "$pass")" "$base/api/v1/auth/login" -o /dev/null -w '%{http_code}')
  if [[ $code == 200 ]]; then ok "the admin logs in"; else bad "login: HTTP $code (a changed admin password goes in .env as OJ_ADMIN_PASSWORD)"; exit 1; fi

  python3 - "$tmp" "$slug" <<'PY'
import json, sys, zipfile
tmp, slug = sys.argv[1:3]
with zipfile.ZipFile(f"{tmp}/cases.zip", "w") as z:
    for i, (a, b) in enumerate([(1, 2), (10, 20), (5, 7)], 1):
        z.writestr(f"{i}.in", f"{a} {b}\n")
        z.writestr(f"{i}.out", f"{a + b}\n")
json.dump({"title": "Smoke: A + B", "subject": "<p>Print the sum of two integers.</p>", "description": "<p>Read $a$ and $b$.</p>",
           "timeLimit": 1000, "memoryLimit": 256, "hardnessLevel": 1, "problemSlug": slug,
           "inputDescription": "<p>Two integers.</p>", "outputDescription": "<p>Their sum.</p>",
           "sampleInput": "1 2", "sampleOutput": "3", "status": "ACTIVE"}, open(f"{tmp}/problem.json", "w"))
PY
  code=$(api "$base/api/v1/problems/$slug" -o /dev/null -w '%{http_code}')
  if [[ $code == 200 ]]; then
    ok "the problem $slug exists from an earlier run"
  else
    code=$(api -F "data=<$tmp/problem.json;type=application/json" -F "file=@$tmp/cases.zip;type=application/zip" "$base/api/v1/problems" -o /dev/null -w '%{http_code}')
    if [[ $code == 200 ]]; then ok "a problem with three test cases is created (multipart upload through the edge)"; else bad "create problem: HTTP $code"; exit 1; fi
  fi

  id=''
  for ((i = 0; i < 6 && ${#id} == 0; i++)); do   # one submission per user per few seconds: wait it out
    id=$(api -H 'Content-Type: application/json' \
      -d "{\"sourceCode\":\"a, b = map(int, input().split())\\nprint(a + b)\",\"languageIdentifier\":\"python3\",\"problemSlug\":\"$slug\"}" \
      "$base/api/v1/submissions" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["data"]["id"])
except Exception: print("")')
    [[ -n $id ]] || sleep 5
  done
  [[ -n $id ]] || { bad "submit: no submission id came back"; exit 1; }
  status=6
  for ((i = 0; i < 60 && (status == 6 || status == 7); i++)); do
    sleep 1
    status=$(api "$base/api/v1/submissions/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["status"])')
  done
  if [[ $status == 0 ]]; then ok "the submission is judged ACCEPTED (queue, Kafka, worker, MinIO, sandbox and back)"; else bad "the submission ended with status $status (0 is ACCEPTED)"; fi

  sleep 4
  api -H 'Content-Type: application/json' \
    -d "{\"sourceCode\":\"print(sum(map(int, input().split())))\",\"languageIdentifier\":\"python3\",\"problemSlug\":\"$slug\",\"cases\":[{\"input\":\"1 2\\n\",\"expectedOutput\":\"3\\n\"},{\"input\":\"5 5\\n\"}]}" \
    "$base/api/v1/submissions/run" -o "$tmp/run.json" || true
  if python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["data"]["cases"]; sys.exit(0 if len(c)==2 and all(x["result"]==0 for x in c) else 1)' "$tmp/run.json" 2> /dev/null; then ok "Run answers each of its two cases (the run lane, one consumer group per instance)"; else bad "Run did not answer two accepted cases"; fi
  exit "$fail"
}

case ${1:-} in
  doctor) cmd_doctor ;;
  init) cmd_init ;;
  env) cmd_env ;;   # only the .env files (init runs it; the test calls it alone)
  build) cmd_build ;;
  up) cmd_up ;;
  smoke) cmd_smoke ;;
  status) cmd_status ;;
  down) shift; cmd_down "$@" ;;
  *) echo "usage: $0 doctor|init|build|up|smoke|status|down [--volumes]" >&2; exit 2 ;;
esac
