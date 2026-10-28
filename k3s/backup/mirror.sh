#!/bin/bash
# Step 2 of the nightly backup (container mirror): the test-case bucket copied into the staging directory over TLS, as MinIO's root
# account (from the Secret minio-init), and its object count appended to counts.tsv (exact: nothing else writes to a bucket that
# only problem-service changes, and the drill compares it with what the snapshot restores).
set -euo pipefail
umask 077
export HOME=/tmp SSL_CERT_FILE=/etc/oj/tls/ca.crt
staging=/staging
# the network policy that admits this pod is programmed a moment after it starts: wait for MinIO instead of failing the night
for _ in $(seq 1 30); do
  (exec 3<>/dev/tcp/minio/9000) 2> /dev/null && break
  sleep 2
done
echo "mirror bucket $MINIO_BUCKET"
MC_HOST_local="https://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@minio:9000" mc mirror --overwrite "local/$MINIO_BUCKET" "$staging/minio"
# the MinIO image has no find: mc lists the local copy, one line per object
n=$(mc ls --recursive "$staging/minio" | wc -l | tr -d ' ')
printf 'minio_objects\t%s\t%s\n' "$n" "$n" >> "$staging/counts.tsv"
echo "mirrored $n objects"
