"""The Secrets of the stack and the .env keys each one takes: the one table that env-to-secrets.sh (local overlay, CI) and
vault.sh seed (the server, through Vault) both read, and that gen_vault.py names the VaultStaticSecrets from."""
import os

import dotenv   # k3s/scripts/dotenv.py: .env files read the way compose reads them

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


def secrets(dir_):
    """Yield (name, {key: value}) for every Secret, reading the .env files in dir_. Raises ValueError (a message for the
    caller to print) when a file or a required key is missing; Secrets before it have been yielded already."""
    for name, file, keys in SECRETS:
        path = os.path.join(dir_, file)
        if not os.path.exists(path):
            raise ValueError(f"{path} is missing (scripts/local-stack.sh init makes the .env files)")
        values = dotenv.parse(path)
        if keys is not None:
            missing = [src for src in keys.values() if src not in values]
            if name in OPTIONAL:
                values = {**{src: "" for src in missing}, **values}
                missing = []
            if missing:
                raise ValueError(f"{file} has no {', '.join(missing)}")
            values = {out: values[src] for out, src in keys.items()} | {k: values[k] for k in EXTRA.get(name, []) if values.get(k)}
        yield name, values
