#!/bin/bash
# 페일백 마지막 단계: DR 서버(EC2Backup)에서 SSM Run Command 로 root 권한 실행
#   1. nginx 를 원본 설정(온프레 WireGuard 터널) 으로 되돌림
#   2. 복원 표시 삭제 (다음 장애 때 다시 S3 백업으로 복원되게)
#   3. recover.sh 가 만든 환경 삭제 -> 다시 "쿠버네티스만 설치된 상태"로
#      (onprem Terraform destroy + Terraform 이 지우지 못하는 Istio / 네임스페이스 / PV / CRD 정리)
#      NFS 데이터(/data/*) 와 앱 이미지는 남김
# 온프레 onprem/scripts/failback.sh 가 CodeBuild(DR_ACTION=failback-finish) 로 실행함
# 진행 로그: /var/log/wegovy-dr.log
set -euo pipefail
exec > >(tee -a /var/log/wegovy-dr.log) 2>&1

: "${SRC_DIR:?}" "${MONGO_PASSWORD_PARAMETER:?}" "${AWS_REGION:?}"
export HOME=/root
export PATH=$PATH:/usr/local/bin:/usr/local/sbin
# shellcheck source=lib-terraform.sh
source "$SRC_DIR/aws-dr/scripts/lib-terraform.sh"

NGINX_CONF=/etc/nginx/conf.d/alpaca-proxy.conf
NGINX_BACKUP=/etc/nginx/dr-backup/alpaca-proxy.conf.onprem
STATE_DIR=/var/lib/wegovy-dr
NAMESPACES="ai app db monitor"

log() { echo "$1 $(date -Is)"; }
log DR_FAILBACK_FINISH_START

# ---------- 1. nginx 원복 ----------
if [ -f "$NGINX_BACKUP" ]; then
  cp "$NGINX_BACKUP" "$NGINX_CONF"
  nginx -t
  systemctl reload nginx
  rm -f "$NGINX_BACKUP"
  log DR_TRAFFIC_ONPREM
else
  echo "nginx 원본 백업이 없음 - 전환된 적 없음, 건너뜀"
fi

# ---------- 2. 복원 표시 삭제 ----------
rm -f "$STATE_DIR/restored"

# ---------- 3. DR 환경 삭제 ----------
tf_init

# 네임스페이스는 코드에 prevent_destroy (온프레 보호용) -> state 에서만 빼고 아래에서 kubectl 로 삭제
for ns in $NAMESPACES; do
  if tf state list | grep -qx "kubernetes_namespace_v1.this\[\"$ns\"\]"; then
    tf state rm "kubernetes_namespace_v1.this[\"$ns\"]" >/dev/null
  fi
done
tf destroy -auto-approve
log DR_ENV_DESTROYED

# Terraform 이 지우지 못하는 것: Istio(istioctl 로 설치), 네임스페이스, Retain PV, Prometheus CRD
istioctl uninstall --purge -y || true
# shellcheck disable=SC2086
kubectl delete namespace istio-system $NAMESPACES --ignore-not-found --wait=true --timeout=300s
kubectl get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{" "}{.spec.claimRef.namespace}{"\n"}{end}' \
  | awk '$2=="db" || $2=="monitor" {print $1}' | xargs -r kubectl delete pv
kubectl get crd -o name | grep 'monitoring.coreos.com' | xargs -r kubectl delete
log DR_FAILBACK_FINISH_DONE
