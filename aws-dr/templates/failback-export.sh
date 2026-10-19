#!/usr/bin/env bash
# Installed on the AWS DR master by the patch instructions in PATCHES.md.
set -Eeuo pipefail
umask 077

RUN_ID="${1:?run ID required}"
BUCKET="${2:?bucket required}"
PREFIX="${3:-failback}"
REGION="${4:-ap-northeast-2}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid run ID" >&2; exit 2; }

export KUBECONFIG=/etc/kubernetes/admin.conf
WORK="/var/lib/dr-failback/${RUN_ID}"
STATE="${WORK}/state"
mkdir -p "${WORK}/db-data" "${STATE}"
chmod 700 "${WORK}" "${STATE}"
SELECTOR="dr-failback-managed=true"
PUBLISHED=0

resume_aws_writers() {
  local f ns name replicas suspended
  if [[ -f "${STATE}/deployments.tsv" ]]; then
    while read -r ns name replicas; do
      [[ -n "${ns:-}" && -n "${name:-}" && "${replicas:-}" =~ ^[0-9]+$ ]] || continue
      kubectl scale deployment "${name}" -n "${ns}" --replicas="${replicas}" || true
    done < "${STATE}/deployments.tsv"
  fi
  if [[ -f "${STATE}/cronjobs.tsv" ]]; then
    while read -r ns name suspended; do
      [[ -n "${ns:-}" && -n "${name:-}" ]] || continue
      if [[ "${suspended}" != "true" ]]; then
        kubectl patch cronjob "${name}" -n "${ns}" --type=merge -p '{"spec":{"suspend":false}}' || true
      fi
    done < "${STATE}/cronjobs.tsv"
  fi
}

on_exit() {
  rc=$?
  if [[ "$rc" -ne 0 && "$PUBLISHED" -eq 0 ]]; then
    echo "Export failed before publishing READY; restoring original AWS writer replicas/schedules." >&2
    resume_aws_writers
  fi
  exit "$rc"
}
trap on_exit EXIT

kubectl get nodes -o wide
kubectl -n db wait --for=condition=Ready pod/mongodb-0 --timeout=180s

# Only explicitly labelled application writers are paused. MongoDB itself must NOT have this label.
kubectl get deployments -A -l "${SELECTOR}" \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas' --no-headers \
  | awk '{$1=$1; print $1, $2, $3}' > "${STATE}/deployments.tsv"
kubectl get cronjobs -A -l "${SELECTOR}" \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend' --no-headers \
  | awk '{$1=$1; print $1, $2, $3}' > "${STATE}/cronjobs.tsv"

if [[ ! -s "${STATE}/deployments.tsv" && ! -s "${STATE}/cronjobs.tsv" ]]; then
  echo "No labelled writer Deployment/CronJob found. Label all write-capable workloads with ${SELECTOR}; refusing to dump." >&2
  exit 20
fi

ACTIVE_JOBS="$(kubectl get jobs -A -l "${SELECTOR}" -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ACTIVE:.status.active' --no-headers | awk '$3+0>0 {print}')"
if [[ -n "${ACTIVE_JOBS}" ]]; then
  echo "Active labelled Jobs must finish or be stopped before failback:\n${ACTIVE_JOBS}" >&2
  exit 21
fi

while read -r ns name replicas; do
  [[ -n "${ns:-}" && -n "${name:-}" ]] || continue
  kubectl scale deployment "${name}" -n "${ns}" --replicas=0
 done < "${STATE}/deployments.tsv"
while read -r ns name suspended; do
  [[ -n "${ns:-}" && -n "${name:-}" ]] || continue
  kubectl patch cronjob "${name}" -n "${ns}" --type=merge -p '{"spec":{"suspend":true}}'
done < "${STATE}/cronjobs.tsv"

# Wait on Deployment status itself (not only pod labels), so a missing pod-template label
# cannot falsely report that a scaled-down Deployment has stopped.
for i in $(seq 1 60); do
  READY_TOTAL=0
  while read -r ns name replicas; do
    [[ -n "${ns:-}" && -n "${name:-}" ]] || continue
    ready="$(kubectl get deployment "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    [[ -n "$ready" ]] && READY_TOTAL=$((READY_TOTAL + ready))
  done < "${STATE}/deployments.tsv"
  [[ "$READY_TOTAL" -eq 0 ]] && break
  sleep 5
done
READY_TOTAL=0
while read -r ns name replicas; do
  [[ -n "${ns:-}" && -n "${name:-}" ]] || continue
  ready="$(kubectl get deployment "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ -n "$ready" ]] && READY_TOTAL=$((READY_TOTAL + ready))
done < "${STATE}/deployments.tsv"
if [[ "$READY_TOTAL" -ne 0 ]]; then
  echo "Writer Deployment pods did not stop; refusing to export a potentially inconsistent backup." >&2
  exit 22
fi

# Uses the same tool-in-container assumption as the current aws-dr master.sh.tftpl.
# If mongodump is not present in the mongo:6.0 image, build/use a pinned MongoDB Database Tools image instead.
kubectl -n db exec mongodb-0 -- /bin/sh -ec \
  'mongodump --archive --username "$MONGO_INITDB_ROOT_USERNAME" --password="$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --nsExclude="admin.*" --nsExclude="config.*"' \
  > "${WORK}/db-data/mongodb.archive"
test -s "${WORK}/db-data/mongodb.archive"

PACKAGE="${WORK}/backup.tar.gz"
tar -czf "${PACKAGE}" -C "${WORK}" db-data/mongodb.archive
sha256sum "${PACKAGE}" | awk '{print $1}' > "${WORK}/backup.tar.gz.sha256"

aws s3 cp "${PACKAGE}" "s3://${BUCKET}/${PREFIX}/runs/${RUN_ID}/backup.tar.gz" --region "$REGION"
aws s3 cp "${WORK}/backup.tar.gz.sha256" "s3://${BUCKET}/${PREFIX}/runs/${RUN_ID}/backup.tar.gz.sha256" --region "$REGION"
printf '%s\n' "${RUN_ID}" > "${WORK}/READY"
# From this point onward, fail closed: the trigger may become visible while the upload is in flight.
PUBLISHED=1
aws s3 cp "${WORK}/READY" "s3://${BUCKET}/${PREFIX}/current/READY" --region "$REGION"

echo "FAILBACK_EXPORT_READY run_id=${RUN_ID}"
echo "AWS writer workloads remain paused until on-prem restore success or an explicit operator decision."
