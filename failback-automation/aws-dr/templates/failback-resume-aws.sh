#!/usr/bin/env bash
set -Eeuo pipefail
RUN_ID="${1:?run ID required}"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
export KUBECONFIG=/etc/kubernetes/admin.conf
STATE="/var/lib/dr-failback/${RUN_ID}/state"
[[ -d "$STATE" ]] || { echo "No saved workload state for ${RUN_ID}" >&2; exit 3; }
while read -r ns name replicas; do
  [[ -n "${ns:-}" && -n "${name:-}" && "${replicas:-}" =~ ^[0-9]+$ ]] || continue
  kubectl scale deployment "${name}" -n "${ns}" --replicas="${replicas}"
done < "${STATE}/deployments.tsv"
while read -r ns name suspended; do
  [[ -n "${ns:-}" && -n "${name:-}" ]] || continue
  if [[ "${suspended}" != "true" ]]; then
    kubectl patch cronjob "${name}" -n "${ns}" --type=merge -p '{"spec":{"suspend":false}}'
  fi
done < "${STATE}/cronjobs.tsv"
echo "AWS writer workloads resumed for run ${RUN_ID}; active-environment marker remains aws-dr."
