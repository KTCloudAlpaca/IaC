#!/bin/bash
# 페일백 마지막 단계: DR 서버(EC2Backup)에서 SSM Run Command 로 root 권한 실행
#   1. nginx 를 원본 설정(온프레 WireGuard 터널) 으로 되돌림
#   2. 복원 표시 삭제 (다음 장애 때 다시 S3 백업으로 복원되게)
#   3. DR 앱/DB 삭제 (데이터는 이미 온프레로 옮겨짐, k3s 는 남겨서 다음 복구를 빠르게)
# 온프레 onprem/scripts/failback.sh 가 CodeBuild(DR_ACTION=failback-finish) 로 실행함
# 진행 로그: /var/log/wegovy-dr.log
set -euo pipefail
exec > >(tee -a /var/log/wegovy-dr.log) 2>&1

export HOME=/root
export PATH=$PATH:/usr/local/bin
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

NGINX_CONF=/etc/nginx/conf.d/alpaca-proxy.conf
NGINX_BACKUP=/etc/nginx/dr-backup/alpaca-proxy.conf.onprem
STATE_DIR=/var/lib/wegovy-dr

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

# ---------- 3. DR 앱/DB 정리 ----------
if command -v k3s >/dev/null 2>&1; then
  kubectl delete namespace app db --ignore-not-found --wait=true --timeout=300s
fi

log DR_FAILBACK_FINISH_DONE
