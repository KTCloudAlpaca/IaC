#!/bin/bash
# DR 서버(EC2Backup)에서 SSM Run Command 로 root 권한 실행
# EC2Backup 에는 onprem Terraform(env/backup.tfvars) 으로 온프레와 같은 환경이 미리 구축되어 있음
#   1. 클러스터 확인
#   2. 앱 이미지 최신화 (ECR -> 온프레와 같은 이름)
#   3. S3 최신 백업으로 MongoDB 복원 (DR 중 한 번만)
#   4. 앱 재시작 (새 이미지 반영, 대기 중 0 개로 내려가 있으면 1 개로)
#   5. nginx 를 온프레(WireGuard 터널) -> 로컬 클러스터로 전환
# 진행 로그: /var/log/wegovy-dr.log  (DR_* 줄의 시각으로 RTO 측정)
set -euo pipefail
exec > >(tee -a /var/log/wegovy-dr.log) 2>&1

: "${BACKUP_BUCKET:?}" "${BACKUP_KEY:?}" "${MONGO_PASSWORD_PARAMETER:?}" "${ECR_REGISTRY:?}" "${APP_IMAGES:?}" "${AWS_REGION:?}"
export HOME=/root
export PATH=$PATH:/usr/local/bin:/usr/local/sbin
export KUBECONFIG=/etc/kubernetes/admin.conf

NGINX_CONF=/etc/nginx/conf.d/alpaca-proxy.conf
NGINX_BACKUP=/etc/nginx/dr-backup/alpaca-proxy.conf.onprem
ONPREM_UPSTREAM=10.200.0.2:30080
FRONTEND_NODEPORT=30080
STATE_DIR=/var/lib/wegovy-dr
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { echo "$1 $(date -Is)"; }
log DR_RECOVER_START

# ---------- 1. 클러스터 확인 ----------
if [ ! -f "$KUBECONFIG" ]; then
  echo "쿠버네티스가 설치되어 있지 않습니다. 쿠버네티스 설치 후 onprem/scripts/prepare-backup-node.sh 와 onprem Terraform(env/backup.tfvars) 로 먼저 구축하세요."
  exit 1
fi
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl -n db get statefulset mongodb >/dev/null
kubectl -n db rollout status statefulset/mongodb --timeout=300s
log DR_CLUSTER_READY

# ---------- 2. 앱 이미지 최신화 ----------
# 온프레와 같은 이름(docker.io/library/<이미지>)으로 저장 -> 같은 Terraform 코드(imagePullPolicy: IfNotPresent)로 실행
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
for img in $APP_IMAGES; do
  ctr -n k8s.io images pull --platform linux/amd64 --user "AWS:$ECR_PASSWORD" "$ECR_REGISTRY/$img" >/dev/null
  ctr -n k8s.io images tag --force "$ECR_REGISTRY/$img" "docker.io/library/$img"
done
log DR_IMAGES_SYNCED

# ---------- 3. S3 최신 백업으로 MongoDB 복원 ----------
MONGO_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$MONGO_PASSWORD_PARAMETER" \
  --with-decryption --query Parameter.Value --output text)

until kubectl -n db exec mongodb-0 -- mongosh --quiet -u root -p "$MONGO_PASSWORD" \
  --authenticationDatabase admin --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1; do
  echo "waiting for mongod..."
  sleep 5
done
log DR_DB_READY

# 다시 실행해도 DR 중에 쌓인 데이터를 덮어쓰지 않도록 한 번만 복원
# (페일백이 끝나면 $STATE_DIR/restored 를 지워야 다음 장애 때 다시 복원됨)
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

# ---------- 4. 앱 재시작 ----------
for d in $(kubectl -n app get deployment -o name); do
  [ "$(kubectl -n app get "$d" -o jsonpath='{.spec.replicas}')" != "0" ] || kubectl -n app scale "$d" --replicas=1
  kubectl -n app rollout restart "$d"
done
for d in $(kubectl -n app get deployment -o name); do
  kubectl -n app rollout status "$d" --timeout=300s
done
log DR_APPS_READY

# ---------- 5. nginx: 온프레 터널 -> 로컬 클러스터 ----------
IMDS_TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
NODE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

# 원본은 conf.d 밖에 보관 (nginx 가 읽지 않는 위치, 페일백 때 이 파일로 되돌림)
mkdir -p "$(dirname "$NGINX_BACKUP")"
[ -f "$NGINX_BACKUP" ] || cp "$NGINX_CONF" "$NGINX_BACKUP"
sed -i "s#$ONPREM_UPSTREAM#$NODE_IP:$FRONTEND_NODEPORT#g" "$NGINX_CONF"
nginx -t
systemctl reload nginx
log DR_TRAFFIC_LOCAL

echo "frontend 응답: $(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$NODE_IP:$FRONTEND_NODEPORT/api/health" || true)"
log DR_RECOVER_DONE
