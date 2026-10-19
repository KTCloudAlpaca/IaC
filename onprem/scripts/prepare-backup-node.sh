#!/bin/bash
# 백업 EC2(쿠버네티스 설치된 상태)에서 onprem Terraform 을 apply 하기 전 서버 준비
#   1. NFS 서버: 온프레 master 와 같은 경로(/data/*) 를 자기 자신에게 export
#   2. 앱 이미지: ECR -> 온프레와 같은 이름(docker.io/library/launcher-*:v1) 으로 containerd 에 저장
#      (같은 app.tf 를 그대로 쓰기 위해. imagePullPolicy: IfNotPresent)
#
# 사용 (백업 EC2 에서): sudo bash prepare-backup-node.sh
# 다음: 온프레 master 에서 scripts/backup-kubeconfig.sh -> terraform apply -var-file=env/backup.tfvars
set -euo pipefail
export PATH=$PATH:/usr/local/bin:/usr/local/sbin

AWS_REGION=${AWS_REGION:-ap-northeast-2}
ECR_REGISTRY=${ECR_REGISTRY:-995342110514.dkr.ecr.ap-northeast-2.amazonaws.com}
APP_IMAGES=${APP_IMAGES:-launcher-frontend:v1 launcher-backend:v1}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
[ "$(id -u)" = 0 ] || { echo "root 로 실행하세요 (sudo)"; exit 1; }

IMDS_TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
NODE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 || hostname -I | awk '{print $1}')
log "노드 IP: $NODE_IP  (env/backup.tfvars 의 nfs_server 와 같아야 함)"

# ---------- 1. NFS 서버 (온프레 master 와 같은 경로) ----------
log "1. NFS 서버"
dnf install -y -q nfs-utils
mkdir -p /data/mongodb /data/mongodb-logs /data/prometheus /data/prometheus-logs /etc/exports.d
chmod 777 /data/mongodb /data/mongodb-logs
cat > /etc/exports.d/k8s.exports <<CONF
/data/mongodb         $NODE_IP(rw,sync,no_subtree_check,no_root_squash)
/data/mongodb-logs    $NODE_IP(rw,sync,no_subtree_check)
/data/prometheus      $NODE_IP(rw,sync,no_subtree_check,no_root_squash)
/data/prometheus-logs $NODE_IP(rw,sync,no_subtree_check)
CONF
systemctl enable --now nfs-server
exportfs -ra
exportfs -v | grep /data

# ---------- 2. 앱 이미지 (ECR -> 온프레와 같은 이름) ----------
log "2. 앱 이미지: $APP_IMAGES"
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
for img in $APP_IMAGES; do
  ctr -n k8s.io images pull --platform linux/amd64 --user "AWS:$ECR_PASSWORD" "$ECR_REGISTRY/$img" >/dev/null
  ctr -n k8s.io images tag --force "$ECR_REGISTRY/$img" "docker.io/library/$img"
done
ctr -n k8s.io images ls -q | grep 'docker.io/library/launcher'

log "완료. 다음: 온프레 master 에서 scripts/backup-kubeconfig.sh -> terraform apply -var-file=env/backup.tfvars"
