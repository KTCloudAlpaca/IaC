#!/bin/sh
set -eu
BUCKET="${BACKUP_BUCKET}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"
ACTIVE_KEY="s3://${BUCKET}/${FAILBACK_PREFIX:-failback}/control/active-environment"
mkdir -p /shared
while true; do
  ACTIVE="$(aws s3 cp "$ACTIVE_KEY" - --region "$REGION" 2>/dev/null | tr -d '\r\n' || true)"
  if [ "$ACTIVE" = "onprem" ] && { [ "${INITIAL_ONPREM_READY:-true}" = "true" ] || [ -f /state/last_successful_run_id ]; }; then
    printf 'ready\n' > /shared/READY.tmp
    mv /shared/READY.tmp /shared/READY
  else
    rm -f /shared/READY /shared/READY.tmp
  fi
  sleep 5
done
