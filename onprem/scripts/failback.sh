#!/bin/bash
# AWS DR -> 온프레 페일백. 온프레 복구 후 master 노드에서 사람이 실행
#   AWS_PROFILE=wegovy ./onprem/scripts/failback.sh
#
#   1. 온프레 노드 Ready + app / monitor / db 서비스 구동 확인
#   2. 온프레 앱을 0 개로 내림 -> /primary-health 실패 -> 트래픽은 계속 DR 에
#   3. 온프레 현재 DB 를 S3 에 스냅샷 (덮어쓰기 전 안전장치)
#   4. CodeBuild(failback-export): DR 앱 중지 + DR DB 덤프 -> S3   (서비스 중단 시작)
#   5. DR 덤프를 온프레 MongoDB 에 복원 -> 온프레 앱 시작 -> Route 53 이 온프레로 전환 (서비스 재개)
#   6. CodeBuild(failback-finish): DR 서버 nginx 원복 + DR 환경 destroy -> 삭제 확인
#
# 필요: kubectl(온프레), aws CLI, 권한 = codebuild:StartBuild/BatchGetBuilds, s3 failback/ 읽기쓰기, ssm:GetParameter
set -euo pipefail

REGION=ap-northeast-2
BUCKET=k8s-hybrid-dr-backup-2026-995342110514-ap-northeast-2-an
CODEBUILD_PROJECT=wegovy-dr-recovery
DR_PUBLIC_IP=43.200.208.156
MONGO_PASSWORD_PARAMETER=/wegovy/dr/mongo-root-password
APP_NAMESPACE=app
APP_DEPLOYMENTS=(backend frontend)

FAILBACK_ID=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d)
STEP=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }

on_exit() {
  local rc=$?
  rm -rf "$WORK"
  [ "$rc" -eq 0 ] && return
  echo
  log "!! ${STEP}단계에서 실패했습니다 (rc=$rc)"
  case "$STEP" in
    1) echo "   아직 아무것도 바뀌지 않았습니다." ;;
    2|3) echo "   온프레 앱은 0 개로 내려가 있고 트래픽은 계속 DR 에 있습니다. 원인 해결 후 다시 실행하세요." ;;
    4|5) echo "   DR 앱이 중지되어 서비스가 중단된 상태일 수 있습니다. 원인 해결 후 바로 다시 실행하세요."
         echo "   (온프레 앱을 복원 없이 먼저 올리면 장애 이전 데이터가 서비스됩니다)" ;;
    6) echo "   온프레 복원은 끝났습니다. DR 서버 정리만 실패 -> CodeBuild 를 DR_ACTION=failback-finish 로 다시 실행하세요." ;;
  esac
}
trap on_exit EXIT

# CodeBuild 를 DR_ACTION 으로 실행하고 끝날 때까지 대기
run_codebuild() {
  local action=$1 build_id status
  build_id=$(aws codebuild start-build --region "$REGION" --project-name "$CODEBUILD_PROJECT" \
    --environment-variables-override \
      "name=DR_ACTION,value=$action,type=PLAINTEXT" \
      "name=FAILBACK_ID,value=$FAILBACK_ID,type=PLAINTEXT" \
    --query build.id --output text)
  log "CodeBuild 시작: $build_id"
  while true; do
    sleep 15
    status=$(aws codebuild batch-get-builds --region "$REGION" --ids "$build_id" \
      --query 'builds[0].buildStatus' --output text)
    [ "$status" = "IN_PROGRESS" ] || break
  done
  log "CodeBuild 결과: $status"
  [ "$status" = "SUCCEEDED" ]
}

mongo() {
  kubectl -n db exec -i mongodb-0 -- "$@" -u root -p "$MONGO_PASSWORD" --authenticationDatabase admin
}

echo "AWS DR -> 온프레 페일백 (ID: $FAILBACK_ID)"
echo "4~5단계 동안 서비스가 잠깐 중단됩니다."
read -r -p "진행할까요? (yes 입력): " answer
[ "$answer" = "yes" ] || { echo "취소했습니다."; exit 0; }

# ---------- 1. 온프레 상태 확인 ----------
STEP=1
log "1-1. 온프레 노드 확인"
kubectl get --raw=/readyz >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=60s
kubectl get nodes

log "1-2. app / monitor / db 서비스 구동 확인"
for ns in app monitor db; do
  for w in $(kubectl -n "$ns" get deployment,statefulset,daemonset -o name); do
    kubectl -n "$ns" rollout status "$w" --timeout=120s >/dev/null
    echo "   OK  $ns/$w"
  done
done
MONGO_PASSWORD=$(aws ssm get-parameter --region "$REGION" --name "$MONGO_PASSWORD_PARAMETER" \
  --with-decryption --query Parameter.Value --output text)
[ "$(mongo mongosh --quiet --eval 'db.adminCommand("ping").ok' | tail -1)" = "1" ]

# 원래 replica 수 기억 (다시 실행해서 0 이면 1 로)
declare -A REPLICAS
for d in "${APP_DEPLOYMENTS[@]}"; do
  r=$(kubectl -n "$APP_NAMESPACE" get deployment "$d" -o jsonpath='{.spec.replicas}')
  REPLICAS[$d]=$(( r > 0 ? r : 1 ))
done

# ---------- 2. 온프레 앱 내리기 ----------
STEP=2
log "2. 온프레 앱 중지 (트래픽은 계속 DR 에)"
kubectl -n "$APP_NAMESPACE" scale deployment "${APP_DEPLOYMENTS[@]}" --replicas=0
for d in "${APP_DEPLOYMENTS[@]}"; do
  kubectl -n "$APP_NAMESPACE" wait --for=delete pod -l "app=$d" --timeout=120s || true
done

# ---------- 3. 온프레 DB 스냅샷 ----------
STEP=3
log "3. 온프레 현재 DB 스냅샷 -> S3"
mongo mongodump --archive > "$WORK/onprem-before.archive"
test -s "$WORK/onprem-before.archive"
aws s3 cp --region "$REGION" --only-show-errors "$WORK/onprem-before.archive" \
  "s3://$BUCKET/failback/onprem-before-$FAILBACK_ID.archive"

# ---------- 4. DR 앱 중지 + DR DB 덤프 ----------
STEP=4
log "4. DR 앱 중지 + DR DB 덤프 (서비스 중단 시작)"
run_codebuild failback-export
aws s3 cp --region "$REGION" --only-show-errors \
  "s3://$BUCKET/failback/dr-$FAILBACK_ID.archive" "$WORK/dr.archive"
test -s "$WORK/dr.archive"

# ---------- 5. 온프레 복원 + 앱 시작 ----------
STEP=5
log "5. DR 데이터를 온프레 MongoDB 에 복원"
mongo mongorestore --archive --drop --stopOnError \
  --nsExclude 'admin.*' --nsExclude 'config.*' < "$WORK/dr.archive"
[ "$(mongo mongosh --quiet --eval 'db.adminCommand("ping").ok' | tail -1)" = "1" ]

log "   온프레 앱 시작 (헬스체크 정상 -> Route 53 이 온프레로 전환)"
for d in "${APP_DEPLOYMENTS[@]}"; do
  kubectl -n "$APP_NAMESPACE" scale deployment "$d" --replicas="${REPLICAS[$d]}"
done
for d in "${APP_DEPLOYMENTS[@]}"; do
  kubectl -n "$APP_NAMESPACE" rollout status deployment "$d" --timeout=300s
done

# ---------- 6. DR 서버 정리 ----------
STEP=6
log "6. DR 서버 nginx 원복 + DR 환경 destroy (삭제 확인은 DR 서버에서 함께 수행)"
run_codebuild failback-finish

# DR 서버 nginx 가 다시 온프레로 전달하는지 (온프레 앱 응답이 돌아와야 함)
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: alpaca.ktproject.cloud" "http://$DR_PUBLIC_IP/api/health" || true)
log "   DR 서버 경유 응답: $code (200 이면 온프레로 전달 중)"
[ "$code" = "200" ]

STEP=done
log "페일백 완료 (ID: $FAILBACK_ID)"
echo "  DR 덤프:        s3://$BUCKET/failback/dr-$FAILBACK_ID.archive"
echo "  온프레 스냅샷:  s3://$BUCKET/failback/onprem-before-$FAILBACK_ID.archive (문제 시 이걸로 되돌림)"
