#!/bin/sh
set -eu
[ -f /work/do_restore ] || { echo "No failback run; report sidecar exits."; exit 0; }
RUN_ID="$(cat /work/run_id)"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"
PREFIX="${FAILBACK_PREFIX:-failback}"
BUCKET="${BACKUP_BUCKET}"
K=/work/tools/kubectl
SUCCESS=0

# If reporting/resume/validation fails unexpectedly, fence on-prem writers again and
# keep AWS marked active. This avoids leaving the partial failback serving writes.
on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$SUCCESS" -ne 1 ]; then
    echo "Failback status handler failed (rc=$rc); fencing on-prem writers and retaining aws-dr as active." >&2
    if [ -x "$K" ] && [ -f "/state/runs/${RUN_ID}/deployments.tsv" ]; then
      while read -r NS NAME REPLICAS; do
        [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] || continue
        "$K" scale deployment "$NAME" -n "$NS" --replicas=0 >/dev/null 2>&1 || true
      done < "/state/runs/${RUN_ID}/deployments.tsv"
    fi
    if [ -x "$K" ] && [ -f "/state/runs/${RUN_ID}/cronjobs.tsv" ]; then
      while read -r NS NAME SUSPEND; do
        [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] || continue
        "$K" patch cronjob "$NAME" -n "$NS" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
      done < "/state/runs/${RUN_ID}/cronjobs.tsv"
    fi
    printf '%s\n' "aws-dr" > /tmp/active-environment-failed
    aws s3 cp /tmp/active-environment-failed "s3://${BUCKET}/${PREFIX}/control/active-environment" --region "$REGION" >/dev/null 2>&1 || true
    printf '%s\n' "FAILED run_id=${RUN_ID} reason=status-handler-exit-${rc}" > /tmp/status-failed.txt
    aws s3 cp /tmp/status-failed.txt "s3://${BUCKET}/${PREFIX}/status/${RUN_ID}/FAILED" --region "$REGION" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap on_exit EXIT

# Wait for restore container to record a terminal result.
for i in $(seq 1 2160); do
  if [ -f /work/restore_success ]; then break; fi
  if [ -f /work/restore_failed ]; then break; fi
  sleep 5
done
if [ ! -f /work/restore_success ] && [ ! -f /work/restore_failed ]; then
  echo "Timed out waiting for restore container." >&2
  printf '%s\n' "reporter-timeout" > /work/restore_failed
fi

if [ -f /work/restore_failed ] || [ -f /work/init_failed ]; then
  REASON="$(cat /work/restore_failed 2>/dev/null || cat /work/init_failed_reason 2>/dev/null || echo init-step-failed)"
  printf '%s\n' "FAILED run_id=${RUN_ID} reason=${REASON}" > /tmp/status.txt
  aws s3 cp /tmp/status.txt "s3://${BUCKET}/${PREFIX}/status/${RUN_ID}/FAILED" --region "$REGION"
  printf '%s\n' "$RUN_ID" > /state/failed_run_id
  echo "Restore failed; application writers remain paused for safety. AWS remains the active environment until an operator resolves the failure."
  exit 1
fi

# Restore the original deployment replica counts and CronJob suspension states.
DEPLOYMENTS="/state/runs/${RUN_ID}/deployments.tsv"
CRONJOBS="/state/runs/${RUN_ID}/cronjobs.tsv"
if [ -x "$K" ] && [ -f "$DEPLOYMENTS" ]; then
  while read -r NS NAME REPLICAS; do
    [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] && [ "${REPLICAS:-}" -ge 0 ] || continue
    "$K" scale deployment "$NAME" -n "$NS" --replicas="$REPLICAS"
  done < "$DEPLOYMENTS"
fi
if [ -x "$K" ] && [ -f "$CRONJOBS" ]; then
  while read -r NS NAME SUSPEND; do
    [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] || continue
    if [ "$SUSPEND" != "true" ]; then
      "$K" patch cronjob "$NAME" -n "$NS" --type=merge -p '{"spec":{"suspend":false}}'
    fi
  done < "$CRONJOBS"
fi

# Wait until originally-running Deployments are available before switching active-environment.
if [ -x "$K" ] && [ -f "$DEPLOYMENTS" ]; then
  while read -r NS NAME REPLICAS; do
    [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] && [ "${REPLICAS:-}" -gt 0 ] 2>/dev/null || continue
    "$K" rollout status deployment "$NAME" -n "$NS" --timeout=300s
  done < "$DEPLOYMENTS"
fi

# Clean temporary payloads before publishing success. Cleanup is best-effort; state lives on /state.
rm -f /work/backup.tar.gz /work/backup.tar.gz.sha256 /work/onprem-before.archive /work/onprem-before.archive.sha256 || true
rm -rf /work/extract || true

printf '%s\n' "$RUN_ID" > /state/last_successful_run_id
rm -f /state/failed_run_id
# Only now permit Route 53's Primary health check to pass. A failure while writing the
# success acknowledgement triggers on_exit, fences these writers, and resets the marker.
printf '%s\n' "onprem" > /tmp/active-environment
aws s3 cp /tmp/active-environment "s3://${BUCKET}/${PREFIX}/control/active-environment" --region "$REGION"
printf '%s\n' "SUCCESS run_id=${RUN_ID} restored_at=$(date -u +%FT%TZ)" > /tmp/status.txt
aws s3 cp /tmp/status.txt "s3://${BUCKET}/${PREFIX}/status/${RUN_ID}/SUCCESS" --region "$REGION"
SUCCESS=1
rm -f /work/do_restore /work/restore_success /work/restore_failed /work/rollback_uploaded /work/run_id || true
echo "Failback run ${RUN_ID} completed; active-environment is now onprem."
