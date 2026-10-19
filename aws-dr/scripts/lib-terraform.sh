#!/bin/bash
# recover.sh / failback-finish.sh 가 source 하는 공통 함수
# DR 서버(EC2Backup) 안에서 onprem Terraform 코드를 env/backup.tfvars 로 실행
#   (CodeBuild 에서는 DR 서버의 쿠버네티스 API(6443) 에 접근할 수 없어서 서버 안에서 실행)
# state 는 /opt/wegovy-dr/terraform 에 보관 (장애 중에는 온프레 master 가 없으므로)

: "${SRC_DIR:?}" "${MONGO_PASSWORD_PARAMETER:?}" "${AWS_REGION:?}"

TERRAFORM_VERSION=1.16.5
ISTIO_VERSION=1.31.1
DR_HOME=/opt/wegovy-dr
TF_DIR=$DR_HOME/terraform
BIN_DIR=$DR_HOME/bin
export KUBECONFIG=/etc/kubernetes/admin.conf
export PATH=$BIN_DIR:$PATH
export TF_IN_AUTOMATION=1
export TF_PLUGIN_CACHE_DIR=$DR_HOME/plugin-cache

node_ip() {
  local token
  token=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/local-ipv4
}

# Terraform / istioctl 이 없으면 설치 (온프레 master 와 같은 버전)
install_tools() {
  mkdir -p "$BIN_DIR" "$TF_PLUGIN_CACHE_DIR"
  if ! terraform version 2>/dev/null | grep -q "v$TERRAFORM_VERSION"; then
    curl -fsSL -o /tmp/terraform.zip \
      "https://releases.hashicorp.com/terraform/$TERRAFORM_VERSION/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("terraform", sys.argv[2])' /tmp/terraform.zip "$BIN_DIR"
    chmod 755 "$BIN_DIR/terraform"
  fi
  if ! istioctl version --remote=false 2>/dev/null | grep -q "$ISTIO_VERSION"; then
    curl -fsSL "https://github.com/istio/istio/releases/download/$ISTIO_VERSION/istioctl-$ISTIO_VERSION-linux-amd64.tar.gz" \
      | tar -xz -C "$BIN_DIR"
  fi
}

# recovery.zip 의 onprem 코드를 작업 폴더로 복사 (state 와 provider 캐시는 유지)
sync_code() {
  mkdir -p "$TF_DIR"
  find "$TF_DIR" -mindepth 1 -maxdepth 1 ! -name terraform.tfstate.d ! -name .terraform -exec rm -rf {} +
  cp -a "$SRC_DIR/onprem/." "$TF_DIR/"
}

# onprem Terraform 을 백업 환경 값으로 실행: tf apply / tf destroy / tf state ...
tf() {
  (
    cd "$TF_DIR"
    TF_VAR_mongo_root_password=$(aws ssm get-parameter --region "$AWS_REGION" --name "$MONGO_PASSWORD_PARAMETER" \
      --with-decryption --query Parameter.Value --output text)
    export TF_VAR_mongo_root_password
    case "$1" in
      apply | destroy | plan)
        terraform "$@" -input=false -no-color \
          -var-file=env/backup.tfvars \
          -var "kubeconfig_path=$KUBECONFIG" \
          -var "nfs_server=$(node_ip)" \
          -var "istioctl_path=$BIN_DIR/istioctl"
        ;;
      *) terraform "$@" ;;
    esac
  )
}

tf_init() {
  install_tools
  sync_code
  (cd "$TF_DIR" && terraform init -input=false -no-color >/dev/null && terraform workspace select -or-create backup >/dev/null)
}
