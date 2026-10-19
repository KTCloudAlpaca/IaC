#!/bin/sh
set -eu
BUCKET="${BACKUP_BUCKET}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"
PREFIX="${FAILBACK_PREFIX:-failback}"

mkdir -p /work /state/runs
# Work PVC is reused between CronJob pods; clear transient files only at the start of a new pod.
rm -rf /work/*
if ! aws s3 cp "s3://${BUCKET}/${PREFIX}/current/READY" /tmp/failback-ready --region "$REGION" >/dev/null 2>&1; then
  echo "No failback trigger published; nothing to do."
  exit 0
fi
RUN_ID="$(tr -d '\r\n' < /tmp/failback-ready)"
case "$RUN_ID" in
  ""|*[!A-Za-z0-9._-]*) echo "Invalid run id in failback READY marker" >&2; exit 2 ;;
esac
printf '%s\n' "$RUN_ID" > /work/run_id
# Once a run ID is known, convert download/validation errors into a failure marker so the reporting sidecar can notify CodeBuild.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "fetch-backup failed rc=$rc" > /work/init_failed_reason; touch /work/init_failed /work/do_restore; exit 0; fi' EXIT
if [ -f /state/last_successful_run_id ] && [ "$(cat /state/last_successful_run_id)" = "$RUN_ID" ]; then
  echo "Run $RUN_ID already restored successfully."
  exit 0
fi
if [ -f /state/failed_run_id ] && [ "$(cat /state/failed_run_id)" = "$RUN_ID" ]; then
  echo "Run $RUN_ID previously failed; refusing an automatic retry. Resolve manually and clear /state/failed_run_id only after review." >&2
  exit 0
fi
mkdir -p "/state/runs/${RUN_ID}" /work/extract
touch /work/do_restore
aws s3 cp "s3://${BUCKET}/${PREFIX}/runs/${RUN_ID}/backup.tar.gz" /work/backup.tar.gz --region "$REGION"
aws s3 cp "s3://${BUCKET}/${PREFIX}/runs/${RUN_ID}/backup.tar.gz.sha256" /work/backup.tar.gz.sha256 --region "$REGION"
EXPECTED="$(tr -d '\r\n' < /work/backup.tar.gz.sha256)"
ACTUAL="$(sha256sum /work/backup.tar.gz | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || { echo "Backup SHA-256 mismatch" >&2; exit 3; }
tar -tzf /work/backup.tar.gz >/dev/null
tar -xzf /work/backup.tar.gz -C /work/extract
test -s /work/extract/db-data/mongodb.archive
echo "Validated failback backup for run $RUN_ID."
