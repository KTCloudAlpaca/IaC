#!/bin/bash
# DR 서버(EC2Backup, Amazon Linux 2023)에서 SSM Run Command 로 root 권한 실행
#   1. k3s 기동 (없으면 설치) + ECR 로그인
#   2. MongoDB / mongo-express 배포
#   3. S3 최신 백업으로 복원 (DR 중 한 번만)
#   4. s3://<버킷>/dr-manifests/ 의 앱 YAML 배포 (이미지는 ECR)
#   5. nginx 를 온프레(WireGuard 터널) -> 로컬 클러스터로 전환
# 진행 로그: /var/log/wegovy-dr.log  (DR_* 줄의 시각으로 RTO 측정)
set -euo pipefail
exec > >(tee -a /var/log/wegovy-dr.log) 2>&1

: "${BACKUP_BUCKET:?}" "${BACKUP_KEY:?}" "${MONGO_PASSWORD_PARAMETER:?}" "${ECR_REGISTRY:?}" "${AWS_REGION:?}"
export HOME=/root
export PATH=$PATH:/usr/local/bin
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

NGINX_CONF=/etc/nginx/conf.d/alpaca-proxy.conf
NGINX_BACKUP=/etc/nginx/dr-backup/alpaca-proxy.conf.onprem
ONPREM_UPSTREAM=10.200.0.2:30080
FRONTEND_NODEPORT=30080
STATE_DIR=/var/lib/wegovy-dr
WORK=$(mktemp -d)

log() { echo "$1 $(date -Is)"; }
log DR_RECOVER_START

# ---------- 1. k3s ----------
# 미리 설치해 두면 이 단계는 바로 넘어감 (RTO 단축)
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io |
    INSTALL_K3S_SKIP_SELINUX_RPM=true \
    INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 600" sh -
fi
# ECR 로그인: k3s(containerd)가 앱 이미지를 받을 수 있게 토큰 등록 (12시간 유효, 받은 이미지는 노드에 남음)
# DR 서버 IAM 역할에 AmazonEC2ContainerRegistryReadOnly 필요
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
mkdir -p /etc/rancher/k3s
umask 077
cat > /etc/rancher/k3s/registries.yaml <<EOF
configs:
  "$ECR_REGISTRY":
    auth:
      username: AWS
      password: "$ECR_PASSWORD"
EOF
umask 022
systemctl restart k3s
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 3; done
log DR_CLUSTER_READY

# ---------- 2. MongoDB / mongo-express (온프레 db 네임스페이스와 같은 구성) ----------
MONGO_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$MONGO_PASSWORD_PARAMETER" \
  --with-decryption --query Parameter.Value --output text)

kubectl create namespace db --dry-run=client -o yaml | kubectl apply -f -
kubectl -n db create secret generic mongodb-root \
  --from-literal=username=root \
  --from-literal=password="$MONGO_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: db
spec:
  replicas: 1
  serviceName: mongodb
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      containers:
        - name: mongodb
          image: mongo:6.0
          ports:
            - containerPort: 27017
          env:
            - name: MONGO_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef: { name: mongodb-root, key: username }
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef: { name: mongodb-root, key: password }
          volumeMounts:
            - name: mongodb-data
              mountPath: /data/db
  volumeClaimTemplates:
    - metadata:
        name: mongodb-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: db
spec:
  type: NodePort
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
      nodePort: 30017
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongo-express
  namespace: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mongo-express
  template:
    metadata:
      labels:
        app: mongo-express
    spec:
      containers:
        - name: mongo-express
          image: mongo-express:latest
          ports:
            - containerPort: 8081
          env:
            - name: ME_CONFIG_MONGODB_SERVER
              value: mongodb.db.svc.cluster.local
            - name: ME_CONFIG_MONGODB_PORT
              value: "27017"
            - name: ME_CONFIG_MONGODB_ENABLE_ADMIN
              value: "true"
            - name: ME_CONFIG_MONGODB_AUTH_DATABASE
              value: admin
            - name: ME_CONFIG_MONGODB_ADMINUSERNAME
              valueFrom:
                secretKeyRef: { name: mongodb-root, key: username }
            - name: ME_CONFIG_MONGODB_ADMINPASSWORD
              valueFrom:
                secretKeyRef: { name: mongodb-root, key: password }
---
apiVersion: v1
kind: Service
metadata:
  name: mongo-express
  namespace: db
spec:
  type: NodePort
  selector:
    app: mongo-express
  ports:
    - port: 8081
      targetPort: 8081
      nodePort: 30081
EOF

kubectl -n db rollout status statefulset/mongodb --timeout=600s
until kubectl -n db exec mongodb-0 -- mongosh --quiet -u root -p "$MONGO_PASSWORD" \
  --authenticationDatabase admin --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1; do
  echo "waiting for mongod..."
  sleep 5
done
log DR_DB_READY

# ---------- 3. S3 최신 백업으로 복원 ----------
# 다시 실행해도 DR 중에 쌓인 데이터를 덮어쓰지 않도록 한 번만 복원
# (페일백이 끝나면 $STATE_DIR/restored 를 지워야 다음 장애 때 다시 복원됨)
if [ ! -f "$STATE_DIR/restored" ]; then
  echo "DR_BACKUP_LAST_MODIFIED $(aws s3api head-object --region "$AWS_REGION" \
    --bucket "$BACKUP_BUCKET" --key "$BACKUP_KEY" --query LastModified --output text)"

  aws s3 cp --region "$AWS_REGION" "s3://$BACKUP_BUCKET/$BACKUP_KEY" "$WORK/backup.tar.gz"
  tar -xzf "$WORK/backup.tar.gz" -C "$WORK" ./db-data/mongodb.archive

  # admin/config DB 는 제외 (root 계정은 위에서 만든 것 유지)
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

# ---------- 4. 앱 배포 ----------
# 앱 YAML 은 aws-bootstrap 이 aws-dr/manifests/ 를 s3://<버킷>/dr-manifests/ 로 올려둠

# backend 가 쓰는 MongoDB 접속 정보 (온프레 backend-secret 과 같은 형식, 비밀번호만 URL 인코딩)
MONGO_PASSWORD_URL=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$MONGO_PASSWORD")
kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -
kubectl -n app create secret generic backend-secret \
  --from-literal=MONGODB_URI="mongodb://root:$MONGO_PASSWORD_URL@mongodb.db.svc.cluster.local:27017/launcher?authSource=admin" \
  --dry-run=client -o yaml | kubectl apply -f -

mkdir -p "$WORK/manifests"
aws s3 cp --region "$AWS_REGION" "s3://$BACKUP_BUCKET/dr-manifests/" "$WORK/manifests" --recursive || true
if find "$WORK/manifests" -name '*.y*ml' | grep -q .; then
  kubectl apply -R -f "$WORK/manifests"
  for d in $(kubectl -n app get deploy -o name 2>/dev/null); do
    kubectl -n app rollout status "$d" --timeout=300s
  done
  log DR_APPS_APPLIED
else
  echo "dr-manifests/ 가 비어 있음 - 앱 배포 건너뜀"
fi

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

echo "frontend 응답: $(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$NODE_IP:$FRONTEND_NODEPORT/" || true)"
log DR_RECOVER_DONE
