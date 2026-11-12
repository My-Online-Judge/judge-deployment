#!/usr/bin/env bash
# docker-compose.cgroup.yml (judge-server spec section 14): merged over docker-compose.yml it gives each Go sandbox its own
# slice, read-write at /oj-cgroup, and CGROUP_MODE (auto unless OJ_CGROUP_MODE says otherwise),
# and changes nothing else about the sandboxes: no privileged, the same six capabilities, the same limits, read-only root.
# Works on a copy of the .example files; prints descriptions.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

for f in .env*.example; do cp "$f" "$tmp/$f"; done
OJ_DEPLOY_DIR=$tmp bash scripts/local-stack.sh env > /dev/null
compose() { docker compose --project-directory "$tmp" "$@" config --format json; }
base=$(compose -f "$PWD/docker-compose.yml")
merged=$(compose -f "$PWD/docker-compose.yml" -f "$PWD/docker-compose.cgroup.yml")
required=$(OJ_CGROUP_MODE=required compose -f "$PWD/docker-compose.yml" -f "$PWD/docker-compose.cgroup.yml")

python3 - "$base" "$merged" "$required" <<'PY' || fail=1
import json, sys
base, merged, required = (json.loads(a)["services"] for a in sys.argv[1:4])
bad = []
def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond: bad.append(what)

for name, sub in (("judge-server", "oj-judge-server.slice"), ("judge-server-2", "oj-judge-server-2.slice")):
    b, m, r = base[name], merged[name], required[name]
    mounts = [v for v in m.get("volumes", []) if v.get("target") == "/oj-cgroup"]
    check(len(mounts) == 1 and mounts[0]["type"] == "bind" and mounts[0]["source"] == f"/sys/fs/cgroup/{sub}"
          and not mounts[0].get("read_only"), f"{name}: its own delegated slice, read-write, at /oj-cgroup")
    check(m["environment"].get("CGROUP_MODE") == "auto" and m["environment"].get("CGROUP_ROOT") == "/oj-cgroup",
          f"{name}: CGROUP_MODE is auto by default and CGROUP_ROOT is the mount")
    check(r["environment"].get("CGROUP_MODE") == "required", f"{name}: OJ_CGROUP_MODE=required reaches the server")
    check("CGROUP_MODE" not in b["environment"], f"{name}: without the overlay the server is told nothing (off)")
    for key in ("privileged", "cap_add", "cap_drop", "security_opt", "read_only", "mem_limit", "cpus", "pids_limit", "init", "tmpfs", "image"):
        check(b.get(key) == m.get(key), f"{name}: {key} is the same with and without the overlay")
    check({k: v for k, v in m["environment"].items() if not k.startswith("CGROUP_")} == b["environment"],
          f"{name}: the rest of the environment is unchanged")
    check([v for v in m["volumes"] if v.get("target") != "/oj-cgroup"] == b["volumes"], f"{name}: the other mounts are unchanged")
mounts = {v["source"] for n in ("judge-server", "judge-server-2") for v in merged[n]["volumes"] if v.get("target") == "/oj-cgroup"}
check(len(mounts) == 2, "the two sandboxes never share a delegated slice (one server per slice)")
sys.exit(1 if bad else 0)
PY
exit $fail
