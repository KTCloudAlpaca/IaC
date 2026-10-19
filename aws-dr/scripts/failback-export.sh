#!/bin/bash
# 페일백 1단계: DR 서버(EC2Backup)에서 SSM Run Command 로 root 권한 실행
#   1. DR 앱(app 네임스페이스) 을 0 개로 내려서 쓰기 중지
#   2. DR MongoDB 를 mongodump -> s3://<버킷>/failback/dr-<FAILBACK_ID>.archive
# 온프레 onprem/scripts/failback.sh 가 CodeBuild(DR_ACTION=failback-export) 로 실행함
# 진행 로그: /var/log/wegovy-dr.log
set -euo pipefail
exec > >(tee -a /var/log/wegovy-dr.log) 2>&1

: "${BACKUP_BUCKET:?}" "${MONGO_PASSWORD_PARAMETER:?}" "${FAILBACK_ID:?}" "${AWS_REGION:?}"
export HOME=/root
export PATH=$PATH:/usr/local/bin:/usr/local/sbin
export KUBECONFIG=/etc/kubernetes/admin.conf

DUMP_KEY="failback/dr-$FAILBACK_ID.archive"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { echo "$1 $(date -Is)"; }
log DR_FAILBACK_EXPORT_START

if ! kubectl -n db get pod mongodb-0 >/dev/null 2>&1; then
  echo "DR MongoDB(db/mongodb-0) 가 없습니다. DR 복구가 실행된 적이 없는 것 같습니다."
  exit 1
fi

# ---------- 1. DR 앱 쓰기 중지 ----------
# 덤프 이후에 들어온 데이터가 사라지지 않도록 덤프 전에 앱을 먼저 내림 (이때부터 서비스 중단)
kubectl -n app scale deployment --all --replicas=0
kubectl -n app wait --for=delete pod --all --timeout=180s || true
log DR_FAILBACK_APPS_STOPPED

# ---------- 2. DR MongoDB 덤프 -> S3 ----------
MONGO_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$MONGO_PASSWORD_PARAMETER" \
  --with-decryption --query Parameter.Value --output text)

kubectl -n db exec mongodb-0 -- mongodump --archive \
  -u root -p "$MONGO_PASSWORD" --authenticationDatabase admin \
  > "$WORK/dr.archive"
test -s "$WORK/dr.archive"

aws s3 cp --region "$AWS_REGION" "$WORK/dr.archive" "s3://$BACKUP_BUCKET/$DUMP_KEY"
echo "DR_FAILBACK_DUMP s3://$BACKUP_BUCKET/$DUMP_KEY ($(stat -c %s "$WORK/dr.archive") bytes)"
log DR_FAILBACK_EXPORT_DONE
