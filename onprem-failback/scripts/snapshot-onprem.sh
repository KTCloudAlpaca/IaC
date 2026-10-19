#!/bin/sh
set -eu
[ -f /work/do_restore ] || { echo "No restore needed; skip rollback dump."; exit 0; }
[ ! -f /work/init_failed ] || exit 0
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "snapshot-onprem failed rc=$rc" > /work/init_failed_reason; touch /work/init_failed; exit 0; fi' EXIT
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD is required}"
RUN_ID="$(cat /work/run_id)"
# MongoDB itself remains running. Application writers and scheduled writers were paused in the previous initContainer.
mongodump \
  --host "${MONGO_HOST:-mongodb.db.svc.cluster.local}" \
  --port 27017 \
  --username root \
  --password="$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  --archive=/work/onprem-before.archive \
  --nsExclude='admin.*' \
  --nsExclude='config.*'
test -s /work/onprem-before.archive
sha256sum /work/onprem-before.archive | awk '{print $1}' > /work/onprem-before.archive.sha256
echo "Created rollback dump for run $RUN_ID."
