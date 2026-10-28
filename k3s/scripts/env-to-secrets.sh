#!/usr/bin/env bash
# The compose stack's .env files as the Secrets the pods read (namespace oj). Idempotent: run it again after a change.
#   k3s/scripts/env-to-secrets.sh            apply them to the current cluster
#   k3s/scripts/env-to-secrets.sh --dry-run  print each Secret's name and keys, never a value, and change nothing
# env-identity-db, env-identity, env-problem and env-submission are the files of those names, whole; minio-root and
# minio-init take only the MinIO variables of .env (the other services never see the root account).
# OJ_DEPLOY_DIR: the directory of the .env files (default judge-deployment; tests use a copy).
set -euo pipefail
dir=${OJ_DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
dry=0
case ${1:-} in --dry-run) dry=1 ;; '') ;; *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;; esac

python3 - "$dir" "$dry" <<'PY'
import os, subprocess, sys, tempfile
dir_, dry = sys.argv[1], sys.argv[2] == "1"
MINIO_ROOT = ["MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD"]
MINIO_INIT = MINIO_ROOT + ["MINIO_PROBLEM_ACCESS_KEY", "MINIO_PROBLEM_SECRET_KEY", "MINIO_WORKER_ACCESS_KEY",
                           "MINIO_WORKER_SECRET_KEY", "MINIO_BUCKET"]
SECRETS = [  # name, file, keys (None: every key of the file)
    ("env-identity-db", ".env.identity-db", None),
    ("env-identity", ".env.identity", None),
    ("env-problem", ".env.problem", None),
    ("env-submission", ".env.submission", None),
    ("minio-root", ".env", MINIO_ROOT),
    ("minio-init", ".env", MINIO_INIT),
]

def parse(path):
    values = {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value
    return values

if not dry:
    have = subprocess.run(["kubectl", "get", "namespace", "oj"], capture_output=True).returncode == 0
    if not have:
        subprocess.run(["kubectl", "create", "namespace", "oj"], check=True)
for name, file, keys in SECRETS:
    path = os.path.join(dir_, file)
    if not os.path.exists(path):
        sys.exit(f"env-to-secrets.sh: {path} is missing (scripts/local-stack.sh init makes the .env files)")
    values = parse(path)
    if keys is not None:
        missing = [k for k in keys if k not in values]
        if missing:
            sys.exit(f"env-to-secrets.sh: {file} has no {', '.join(missing)}")
        values = {k: values[k] for k in keys}
    if dry:
        print(name, ",".join(sorted(values)))
        continue
    fd, tmp = tempfile.mkstemp()   # 0600; the values never become command-line arguments
    try:
        with os.fdopen(fd, "w") as f:
            f.write("".join(f"{k}={v}\n" for k, v in values.items()))
        manifest = subprocess.run(["kubectl", "-n", "oj", "create", "secret", "generic", name, f"--from-env-file={tmp}",
                                   "--dry-run=client", "-o", "yaml"], check=True, capture_output=True).stdout
        subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, check=True)
    finally:
        os.remove(tmp)
PY
