#!/bin/bash
# 온프레 master 에서 백업 EC2 클러스터에 접속할 kubeconfig 준비
#   백업 EC2 의 6443 은 외부에 닫혀 있어서 SSH 터널(localhost:16443 -> EC2 6443)로 접속
# 사용: ./onprem/scripts/backup-kubeconfig.sh   ->  ~/.kube/backup.conf
set -euo pipefail

HOST=${BACKUP_HOST:-ec2-user@43.200.208.156}
KEY=${BACKUP_SSH_KEY:-$HOME/ktcloud-cdy.pem}
LOCAL_PORT=${LOCAL_PORT:-16443}
OUT=$HOME/.kube/backup.conf

mkdir -p "$HOME/.kube"
umask 077
ssh -i "$KEY" "$HOST" 'sudo cat /etc/kubernetes/admin.conf' \
  | sed -E "s#server: https://[^ ]+#server: https://127.0.0.1:$LOCAL_PORT#" > "$OUT"

# 터널이 없으면 백그라운드로 연결
if ! ss -ltn "sport = :$LOCAL_PORT" | grep -q LISTEN; then
  ssh -i "$KEY" -fN -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
    -L "$LOCAL_PORT:127.0.0.1:6443" "$HOST"
fi

kubectl --kubeconfig "$OUT" get nodes
echo "kubeconfig: $OUT  (터널 종료: pkill -f 'L $LOCAL_PORT:127.0.0.1:6443')"
