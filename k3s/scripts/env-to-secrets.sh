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

python3 - "$dir" "$dry" <<'PY'
import os, subprocess, sys, tempfile
dir_, dry = sys.argv[1], sys.argv[2] == "1"
MINIO_ROOT = ["MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD"]
MINIO_INIT = MINIO_ROOT + ["MINIO_PROBLEM_ACCESS_KEY", "MINIO_PROBLEM_SECRET_KEY", "MINIO_WORKER_ACCESS_KEY",
                           "MINIO_WORKER_SECRET_KEY", "MINIO_BUCKET"]
same = lambda keys: {k: k for k in keys}
SECRETS = [  # name, file, {key in the Secret: key in the file} (None: every key of the file, unchanged)
    ("env-identity-db", ".env.identity-db", None),
    ("env-identity", ".env.identity", None),
    ("env-problem", ".env.problem", None),
    ("env-submission", ".env.submission", None),
    ("minio-root", ".env", same(MINIO_ROOT)),
    ("minio-init", ".env", same(MINIO_INIT)),
    ("minio-problem", ".env", {"MINIO_ACCESS_KEY": "MINIO_PROBLEM_ACCESS_KEY", "MINIO_SECRET_KEY": "MINIO_PROBLEM_SECRET_KEY"}),
    ("minio-worker", ".env", {"MINIO_ACCESS_KEY": "MINIO_WORKER_ACCESS_KEY", "MINIO_SECRET_KEY": "MINIO_WORKER_SECRET_KEY"}),
    ("judge-token", ".env", same(["JUDGE_SERVER_TOKEN"])),
    ("pg-monitor", ".env", same(["PG_MONITOR_PASSWORD"])),
    ("grafana-admin", ".env", same(["GRAFANA_ADMIN_PASSWORD"])),
    # optional: .env.example keeps these two commented out; without them render.sh leaves Alertmanager UI-only
    ("alertmanager-telegram", ".env", same(["ALERT_TELEGRAM_BOT_TOKEN", "ALERT_TELEGRAM_CHAT_ID"])),
    # optional: where the nightly backup's restic repository is and its password (restic.sh stops with a message when either is
    # empty), and the access keys of an S3 or B2 repository (only the ones .env sets)
    ("restic", ".env", same(["RESTIC_REPOSITORY", "RESTIC_PASSWORD"])),
]
OPTIONAL = {"alertmanager-telegram", "restic"}   # a missing key is an empty value, not an error
EXTRA = {"restic": ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "B2_ACCOUNT_ID", "B2_ACCOUNT_KEY"]}   # taken from the file when it has them

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
        missing = [src for src in keys.values() if src not in values]
        if name in OPTIONAL:
            values = {**{src: "" for src in missing}, **values}
            missing = []
        if missing:
            sys.exit(f"env-to-secrets.sh: {file} has no {', '.join(missing)}")
        values = {out: values[src] for out, src in keys.items()} | {k: values[k] for k in EXTRA.get(name, []) if values.get(k)}
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
