#!/usr/bin/env bash
# The compose stack's .env files as the Secrets the pods read (namespace oj). Idempotent: run it again after a change.
#   k3s/scripts/env-to-secrets.sh            apply them to the current cluster
#   k3s/scripts/env-to-secrets.sh --dry-run  print each Secret's name and keys, never a value, and change nothing
# env-identity-db, env-identity, env-problem and env-submission are the files of those names, whole; the others take only
# what their reader needs from .env: minio-root and minio-init the MinIO root account (read by MinIO and minio-init only), minio-problem the key problem-service
# reads and writes with and minio-worker the read-only key the judge worker fetches test cases with (as MINIO_ACCESS_KEY /
# MINIO_SECRET_KEY, the names their code reads), judge-token the sandbox token, pg-monitor the oj_monitor password the
# postgres-exporters log in with, grafana-admin Grafana's admin password and alertmanager-telegram the Telegram bot token and
# chat id (empty when .env has neither: Alertmanager then only shows alerts in its UI), and restic the nightly backup's repository,
# its password and, for an S3 or B2 repository, the access keys (empty when .env has none: the backup job then stops with a message).
# OJ_DEPLOY_DIR: the directory of the .env files (default judge-deployment; tests use a copy).
set -euo pipefail
dir=${OJ_DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
dry=0
case ${1:-} in --dry-run) dry=1 ;; '') ;; *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;; esac

PYTHONPATH=$(dirname "${BASH_SOURCE[0]}") python3 - "$dir" "$dry" <<'PY'
import os, subprocess, sys, tempfile
import secret_map   # k3s/scripts/secret_map.py: which .env keys make which Secret (vault.sh seed reads the same table)
dir_, dry = sys.argv[1], sys.argv[2] == "1"

if not dry:
    have = subprocess.run(["kubectl", "get", "namespace", "oj"], capture_output=True).returncode == 0
    if not have:
        subprocess.run(["kubectl", "create", "namespace", "oj"], check=True)
try:
    for name, values in secret_map.secrets(dir_):
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
except ValueError as e:
    sys.exit(f"env-to-secrets.sh: {e}")
PY
