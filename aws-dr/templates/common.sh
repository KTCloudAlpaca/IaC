# ---------- master / worker 공통: containerd + kubeadm/kubelet/kubectl + AWS CLI ----------
# (master.sh.tftpl / worker.sh.tftpl 에 그대로 삽입됨, K8S_VERSION 은 앞에서 지정)

swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gpg unzip apt-transport-https
install -m 0755 -d /etc/apt/keyrings

# containerd 2.x (Kubernetes 1.36 은 containerd 1.x 미지원) -> Docker 저장소의 containerd.io 사용
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y containerd.io kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# containerd.io 기본 설정은 CRI 가 꺼져 있어서 기본값으로 다시 생성 + systemd cgroup
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable --now kubelet

# AWS CLI v2 (S3 백업 다운로드, SSM 비밀번호 조회)
curl -fsSL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update

IMDS_TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
