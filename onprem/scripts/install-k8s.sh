#!/bin/bash
# 빈 서버에 온프레와 같은 쿠버네티스 기반을 설치 (Terraform 이 할 수 없는 서버 설치 부분)
#   containerd 2.3.6 / runc 1.5.1 / kubeadm·kubelet·kubectl 1.36.3 / Flannel v0.28.9
#   NFS 서버 (/data/mongodb, /data/mongodb-logs, /data/prometheus, /data/prometheus-logs)
#   앱 이미지: ECR -> 온프레와 같은 이름(docker.io/library/launcher-*:v1) 으로 containerd 에 저장
#   단일 노드라 control-plane 에도 파드를 띄움
#
# 사용 (대상 서버에서): sudo PUBLIC_IP=43.200.208.156 bash install-k8s.sh
# 대상: Amazon Linux 2023 / RHEL 9 계열, 2 vCPU 이상, 메모리 8GB 권장 (Prometheus + Istio 포함)
# 다음: 온프레 master 에서 scripts/backup-kubeconfig.sh -> terraform apply -var-file=env/backup.tfvars
set -euo pipefail
export PATH=$PATH:/usr/local/bin:/usr/local/sbin

K8S_VERSION=1.36.3
K8S_MINOR=1.36
CONTAINERD_VERSION=2.3.6
RUNC_VERSION=1.5.1
FLANNEL_VERSION=v0.28.9
POD_CIDR=10.244.0.0/16
SERVICE_CIDR=10.96.0.0/12
PUBLIC_IP=${PUBLIC_IP:-}
AWS_REGION=${AWS_REGION:-ap-northeast-2}
ECR_REGISTRY=${ECR_REGISTRY:-995342110514.dkr.ecr.ap-northeast-2.amazonaws.com}
APP_IMAGES=${APP_IMAGES:-launcher-frontend:v1 launcher-backend:v1}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
[ "$(id -u)" = 0 ] || { echo "root 로 실행하세요 (sudo)"; exit 1; }

IMDS_TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
NODE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 || hostname -I | awk '{print $1}')
log "노드 IP: $NODE_IP"

# ---------- OS 설정 ----------
log "1. OS 설정"
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab
cat > /etc/modules-load.d/k8s.conf <<'CONF'
overlay
br_netfilter
CONF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<'CONF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
CONF
sysctl --system >/dev/null
dnf install -y -q tar iptables-nft iproute-tc conntrack-tools socat nfs-utils

# ---------- containerd / runc (온프레와 같은 버전) ----------
log "2. containerd $CONTAINERD_VERSION / runc $RUNC_VERSION"
if ! containerd --version 2>/dev/null | grep -q "v$CONTAINERD_VERSION"; then
  curl -fsSL "https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-linux-amd64.tar.gz" | tar -xz -C /usr/local
  curl -fsSL -o /etc/systemd/system/containerd.service "https://raw.githubusercontent.com/containerd/containerd/v$CONTAINERD_VERSION/containerd.service"
  curl -fsSL -o /usr/local/sbin/runc "https://github.com/opencontainers/runc/releases/download/v$RUNC_VERSION/runc.amd64"
  chmod 755 /usr/local/sbin/runc
fi
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

# ---------- kubeadm / kubelet / kubectl ----------
log "3. kubeadm / kubelet / kubectl $K8S_VERSION"
cat > /etc/yum.repos.d/kubernetes.repo <<CONF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
CONF
dnf install -y -q "kubelet-$K8S_VERSION" "kubeadm-$K8S_VERSION" "kubectl-$K8S_VERSION" --disableexcludes=kubernetes
systemctl enable --now kubelet

# ---------- NFS 서버 (온프레 master 와 같은 경로) ----------
log "4. NFS 서버"
mkdir -p /data/mongodb /data/mongodb-logs /data/prometheus /data/prometheus-logs
chmod 777 /data/mongodb /data/mongodb-logs
mkdir -p /etc/exports.d
cat > /etc/exports.d/k8s.exports <<CONF
/data/mongodb         $NODE_IP(rw,sync,no_subtree_check,no_root_squash)
/data/mongodb-logs    $NODE_IP(rw,sync,no_subtree_check)
/data/prometheus      $NODE_IP(rw,sync,no_subtree_check,no_root_squash)
/data/prometheus-logs $NODE_IP(rw,sync,no_subtree_check)
CONF
systemctl enable --now nfs-server
exportfs -ra

# ---------- kubeadm init (온프레와 같은 네트워크 대역) ----------
export KUBECONFIG=/etc/kubernetes/admin.conf
if [ ! -f /etc/kubernetes/admin.conf ]; then
  log "5. kubeadm init"
  cat > /tmp/kubeadm.yaml <<CONF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $NODE_IP
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v$K8S_VERSION
networking:
  podSubnet: $POD_CIDR
  serviceSubnet: $SERVICE_CIDR
apiServer:
  certSANs:
    - 127.0.0.1
    - $NODE_IP
${PUBLIC_IP:+    - $PUBLIC_IP}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
CONF
  kubeadm init --config /tmp/kubeadm.yaml
else
  log "5. kubeadm init (이미 되어 있음 - 건너뜀)"
fi

log "6. Flannel $FLANNEL_VERSION"
kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/$FLANNEL_VERSION/kube-flannel.yml"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl wait --for=condition=Ready node --all --timeout=300s

# ---------- 앱 이미지 (ECR -> 온프레와 같은 이름) ----------
log "7. 앱 이미지: $APP_IMAGES"
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
for img in $APP_IMAGES; do
  ctr -n k8s.io images pull --platform linux/amd64 --user "AWS:$ECR_PASSWORD" "$ECR_REGISTRY/$img" >/dev/null
  ctr -n k8s.io images tag --force "$ECR_REGISTRY/$img" "docker.io/library/$img"
done

for u in ec2-user ubuntu; do
  if id "$u" >/dev/null 2>&1; then
    mkdir -p "/home/$u/.kube"
    cp /etc/kubernetes/admin.conf "/home/$u/.kube/config"
    chown -R "$u:$u" "/home/$u/.kube"
  fi
done

log "완료. 다음: 온프레 master 에서 scripts/backup-kubeconfig.sh -> terraform apply -var-file=env/backup.tfvars"
kubectl get nodes -o wide
