#!/bin/bash
# DR 서버(EC2Backup)에서 SSM Run Command 로 root 권한 실행
# 평소 DR 서버에는 쿠버네티스만 설치되어 있음 -> 장애 시 onprem Terraform 으로 온프레와 같은 환경을 만듦
#   1. 클러스터 확인
#   2. 서버 준비: NFS 서버(/data/*) + 앱 이미지(ECR -> 온프레와 같은 이름)  (onprem/scripts/prepare-backup-node.sh)
#   3. onprem Terraform apply (env/backup.tfvars) -> 네임스페이스, MongoDB, 앱, Prometheus, Istio 등
#   4. S3 최신 백업으로 MongoDB 복원 (DR 중 한 번만)
#   5. nginx 를 로컬 클러스터(30080)로 전환 + reload, 응답 확인
# 진행 로그: /var/log/wegovy-dr.log  (DR_* 줄의 시각으로 RTO 측정)
set -euo pipefail
exec > >(tee -a /var/log/wegovy-dr.log) 2>&1

: "${SRC_DIR:?}" "${BACKUP_BUCKET:?}" "${BACKUP_KEY:?}" "${MONGO_PASSWORD_PARAMETER:?}" "${ECR_REGISTRY:?}" "${APP_IMAGES:?}" "${AWS_REGION:?}"
export HOME=/root
export PATH=$PATH:/usr/local/bin:/usr/local/sbin
# shellcheck source=lib-terraform.sh
source "$SRC_DIR/aws-dr/scripts/lib-terraform.sh"

NGINX_BACKUP_DIR=/etc/nginx/dr-backup
ONPREM_UPSTREAM=10.200.0.2:30080
FRONTEND_NODEPORT=30080
STATE_DIR=/var/lib/wegovy-dr
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { echo "$1 $(date -Is)"; }
log DR_RECOVER_START

# ---------- 1. 클러스터 확인 ----------
if [ ! -f "$KUBECONFIG" ]; then
  echo "DR 서버에 쿠버네티스가 설치되어 있지 않습니다 ($KUBECONFIG 없음)"
  exit 1
fi
kubectl wait --for=condition=Ready node --all --timeout=180s
log DR_CLUSTER_READY

# ---------- 2. 서버 준비 (NFS + 앱 이미지) ----------
ECR_REGISTRY=$ECR_REGISTRY APP_IMAGES=$APP_IMAGES AWS_REGION=$AWS_REGION \
  bash "$SRC_DIR/onprem/scripts/prepare-backup-node.sh"
log DR_NODE_READY

# ---------- 3. 온프레와 같은 환경 생성 (onprem Terraform) ----------
tf_init
tf apply -auto-approve
log DR_ENV_READY

# ---------- 4. S3 최신 백업으로 MongoDB 복원 ----------
MONGO_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$MONGO_PASSWORD_PARAMETER" \
  --with-decryption --query Parameter.Value --output text)

until kubectl -n db exec mongodb-0 -- mongosh --quiet -u root -p "$MONGO_PASSWORD" \
  --authenticationDatabase admin --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1; do
  echo "waiting for mongod..."
  sleep 5
done
log DR_DB_READY

# 다시 실행해도 DR 중에 쌓인 데이터를 덮어쓰지 않도록 한 번만 복원 (failback-finish 가 표시 삭제)
if [ ! -f "$STATE_DIR/restored" ]; then
  echo "DR_BACKUP_LAST_MODIFIED $(aws s3api head-object --region "$AWS_REGION" \
    --bucket "$BACKUP_BUCKET" --key "$BACKUP_KEY" --query LastModified --output text)"

  aws s3 cp --region "$AWS_REGION" "s3://$BACKUP_BUCKET/$BACKUP_KEY" "$WORK/backup.tar.gz"
  tar -xzf "$WORK/backup.tar.gz" -C "$WORK" ./db-data/mongodb.archive

  # admin/config DB 는 제외 (root 계정은 DR 쪽 것을 유지)
  kubectl -n db exec -i mongodb-0 -- mongorestore --archive --drop \
    --nsExclude 'admin.*' --nsExclude 'config.*' \
    -u root -p "$MONGO_PASSWORD" --authenticationDatabase admin \
    < "$WORK/db-data/mongodb.archive"

  mkdir -p "$STATE_DIR"
  date -Is > "$STATE_DIR/restored"
  log DR_DB_RESTORED
else
  echo "이미 복원됨 ($(cat "$STATE_DIR/restored")) - DR 중 데이터 보호를 위해 복원 건너뜀"
fi

for d in $(kubectl -n app get deployment -o name); do
  kubectl -n app rollout status "$d" --timeout=300s
done
log DR_APPS_READY

# ---------- 5. nginx: 로컬 클러스터로 ----------
mkdir -p "$NGINX_BACKUP_DIR"
for f in /etc/nginx/conf.d/*.conf; do
  grep -q "$ONPREM_UPSTREAM" "$f" || continue
  [ -f "$NGINX_BACKUP_DIR/$(basename "$f").onprem" ] || cp "$f" "$NGINX_BACKUP_DIR/$(basename "$f").onprem"
  sed -i "s#$ONPREM_UPSTREAM#127.0.0.1:$FRONTEND_NODEPORT#g" "$f"
done
nginx -t
systemctl reload nginx
sleep 2

# nginx 를 거쳐 DR 앱이 응답하는지 (Route 53 Secondary 헬스체크와 같은 경로)
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: alpaca.ktproject.cloud" http://127.0.0.1/api/health || true)
echo "nginx 경유 DR 앱 응답: $code"
[ "$code" = "200" ]
log DR_TRAFFIC_LOCAL
log DR_RECOVER_DONE
