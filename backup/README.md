# Backups

`backup.sh` writes a nightly restic snapshot of the three Postgres databases (`pg_dump -Fc`), the test-case MinIO bucket,
`.env*` files, `pki/out` and `backups/`. Retention: 7 daily, 4 weekly, 6 monthly. `restore-drill.sh` restores the latest
snapshot into network-less `postgres:16` containers and compares row counts with the `counts.tsv` taken at backup time.

## Setup

    mkdir -p ~/.config/oj-backup && (umask 077; openssl rand -base64 32 > ~/.config/oj-backup/restic-password)

Keep a copy of that password off this machine: without it the snapshots are unreadable. The default repo
(`BACKUP_REPO=/home/tuan/oj-backups/restic`) is on the same disk as the live data, so also copy it off-host.
The env files in the snapshot hold secrets; the repo is encrypted, the password file is not.

## Schedule

    mkdir -p ~/.config/systemd/user
    cp backup/systemd/oj-backup.* ~/.config/systemd/user/
    systemctl --user daemon-reload && systemctl --user enable --now oj-backup.timer
    loginctl enable-linger "$USER"   # run while logged out

## Restore drill

    backup/restore-drill.sh      # exit 0 and only PASS lines means the backup restores

Run it after the first backup and periodically. Environment: `BACKUP_REPO`, `RESTIC_PASSWORD_FILE`.
