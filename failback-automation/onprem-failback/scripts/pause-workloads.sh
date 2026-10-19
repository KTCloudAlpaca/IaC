#!/bin/sh
set -eu
[ -f /work/do_restore ] || { echo "No restore needed; skipping workload pause."; exit 0; }
[ ! -f /work/init_failed ] || exit 0
RUN_ID="$(cat /work/run_id)"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "pause-workloads failed rc=$rc" > /work/init_failed_reason; touch /work/init_failed; exit 0; fi' EXIT
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.3}"
mkdir -p /work/tools "/state/runs/${RUN_ID}"
if [ ! -x /state/tools/kubectl ]; then
  mkdir -p /state/tools
  wget -q "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -O /state/tools/kubectl
  wget -q "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" -O /tmp/kubectl.sha256
  EXPECTED="$(tr -d '\r\n' < /tmp/kubectl.sha256)"
  ACTUAL="$(sha256sum /state/tools/kubectl | awk '{print $1}')"
  [ "$EXPECTED" = "$ACTUAL" ] || { echo "kubectl checksum validation failed" >&2; exit 4; }
  chmod 0755 /state/tools/kubectl
fi
cp /state/tools/kubectl /work/tools/kubectl
K=/work/tools/kubectl

: > "/state/runs/${RUN_ID}/deployments.tsv"
: > "/state/runs/${RUN_ID}/cronjobs.tsv"
: > "/state/runs/${RUN_ID}/jobs-active.txt"
OLD_IFS="$IFS"
IFS=','
for NS in ${FAILBACK_WORKLOAD_NAMESPACES:-app,ai}; do
  [ -n "$NS" ] || continue
  "$K" get deployments -n "$NS" -l dr-failback-managed=true -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas' --no-headers 2>/dev/null \
    | awk -v ns="$NS" 'NF>=2 {print ns, $1, $2}' >> "/state/runs/${RUN_ID}/deployments.tsv" || true
  "$K" get cronjobs -n "$NS" -l dr-failback-managed=true -o custom-columns='NAME:.metadata.name,SUSPEND:.spec.suspend' --no-headers 2>/dev/null \
    | awk -v ns="$NS" 'NF>=2 {print ns, $1, $2}' >> "/state/runs/${RUN_ID}/cronjobs.tsv" || true
  "$K" get jobs -n "$NS" -l dr-failback-managed=true -o custom-columns='NAME:.metadata.name,ACTIVE:.status.active' --no-headers 2>/dev/null \
    | awk -v ns="$NS" '$2+0>0 {print ns, $1, $2}' >> "/state/runs/${RUN_ID}/jobs-active.txt" || true
done
IFS="$OLD_IFS"
if [ -s "/state/runs/${RUN_ID}/jobs-active.txt" ]; then
  cat "/state/runs/${RUN_ID}/jobs-active.txt" >&2
  echo "Active labelled Jobs found. Stop/wait for these Jobs before restore." >&2
  touch /work/init_failed
  exit 0
fi
if [ ! -s "/state/runs/${RUN_ID}/deployments.tsv" ] && [ ! -s "/state/runs/${RUN_ID}/cronjobs.tsv" ]; then
  echo "No writer workloads found in FAILBACK_WORKLOAD_NAMESPACES with label dr-failback-managed=true. Refusing to overwrite DB." >&2
  touch /work/init_failed
  exit 0
fi

while read -r NS NAME REPLICAS; do
  [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] || continue
  "$K" scale deployment "$NAME" -n "$NS" --replicas=0
done < "/state/runs/${RUN_ID}/deployments.tsv"
while read -r NS NAME SUSPEND; do
  [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] || continue
  "$K" patch cronjob "$NAME" -n "$NS" --type=merge -p '{"spec":{"suspend":true}}'
done < "/state/runs/${RUN_ID}/cronjobs.tsv"

for i in $(seq 1 60); do
  READY_TOTAL=0
  while read -r NS NAME REPLICAS; do
    [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] || continue
    READY=$("$K" get deployment "$NAME" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    [ -n "$READY" ] && READY_TOTAL=$((READY_TOTAL + READY))
  done < "/state/runs/${RUN_ID}/deployments.tsv"
  [ "$READY_TOTAL" = "0" ] && break
  sleep 5
done
READY_TOTAL=0
while read -r NS NAME REPLICAS; do
  [ -n "${NS:-}" ] && [ -n "${NAME:-}" ] || continue
  READY=$("$K" get deployment "$NAME" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [ -n "$READY" ] && READY_TOTAL=$((READY_TOTAL + READY))
done < "/state/runs/${RUN_ID}/deployments.tsv"
[ "$READY_TOTAL" = "0" ] || { echo "Writer deployments did not terminate; refusing database restore." >&2; touch /work/init_failed; exit 0; }
touch "/state/runs/${RUN_ID}/workloads-paused"
echo "Writer deployments scaled to zero and CronJobs suspended for run $RUN_ID."
