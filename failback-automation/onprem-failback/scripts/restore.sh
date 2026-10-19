#!/bin/sh
set -eu
[ -f /work/do_restore ] || { echo "No new failback run; nothing to restore."; exit 0; }
if [ -f /work/init_failed ]; then touch /work/restore_failed; exit 0; fi
RUN_ID="$(cat /work/run_id)"
: "${MONGO_ROOT_PASSWORD:?MONGO_ROOT_PASSWORD is required}"
[ -f /work/rollback_uploaded ] || { echo "Rollback backup was not safely uploaded; refusing restore." >&2; exit 8; }
trap 'rc=$?; if [ "$rc" -eq 0 ]; then touch /work/restore_success; else printf "%s\n" "$rc" > /work/restore_failed; fi; exit "$rc"' EXIT

# This is a logical restore into the running On-Prem MongoDB service, not extraction into /data/db.
# admin/config are excluded to preserve the target cluster's root credentials.
mongorestore \
  --host "${MONGO_HOST:-mongodb.db.svc.cluster.local}" \
  --port 27017 \
  --username root \
  --password="$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  --archive=/work/extract/db-data/mongodb.archive \
  --drop \
  --stopOnError \
  --nsExclude='admin.*' \
  --nsExclude='config.*'

# Basic DB-level validation. Add an application/business-level validation endpoint for production.
RESULT="$(mongosh --host "${MONGO_HOST:-mongodb.db.svc.cluster.local}" --port 27017 \
  --username root --password="$MONGO_ROOT_PASSWORD" --authenticationDatabase admin \
  --quiet --eval 'db.adminCommand("ping").ok')"
[ "$RESULT" = "1" ] || { echo "MongoDB ping validation failed: $RESULT" >&2; exit 9; }
echo "MongoDB restore and ping validation succeeded for ${RUN_ID}."
