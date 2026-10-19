#!/bin/sh
set -eu
[ -f /work/do_restore ] || { echo "No restore needed; skip rollback upload."; exit 0; }
RUN_ID="$(cat /work/run_id)"
if [ -f /work/init_failed ]; then
  printf '%s\n' "FAILED run_id=${RUN_ID} reason=$(cat /work/init_failed_reason 2>/dev/null || echo init-step-failed)" > /tmp/status.txt
  aws s3 cp /tmp/status.txt "s3://${BACKUP_BUCKET}/${FAILBACK_PREFIX:-failback}/status/${RUN_ID}/FAILED" --region "${AWS_DEFAULT_REGION:-ap-northeast-2}"
  exit 0
fi
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "upload-rollback failed rc=$rc" > /work/init_failed_reason; touch /work/init_failed; fi' EXIT
aws s3 cp /work/onprem-before.archive "s3://${BACKUP_BUCKET}/${FAILBACK_PREFIX:-failback}/rollback/${RUN_ID}/onprem-before.archive" --region "${AWS_DEFAULT_REGION:-ap-northeast-2}"
aws s3 cp /work/onprem-before.archive.sha256 "s3://${BACKUP_BUCKET}/${FAILBACK_PREFIX:-failback}/rollback/${RUN_ID}/onprem-before.archive.sha256" --region "${AWS_DEFAULT_REGION:-ap-northeast-2}"
touch /work/rollback_uploaded
echo "Rollback archive uploaded before applying AWS data."
