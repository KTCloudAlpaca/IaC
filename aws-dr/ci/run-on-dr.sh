#!/bin/bash
# CodeBuild 에서 실행: DR 서버(EC2Backup)에 SSM Run Command 로 스크립트 실행을 지시하고 끝날 때까지 기다림
#   DR 서버가 S3 의 recovery.zip(aws-dr/ + onprem/) 을 직접 받아서 /opt/wegovy-dr/src 에 풀고 실행
#   DR_ACTION=recover         : 장애 시 복구 (기본값, EventBridge)
#   DR_ACTION=failback-export : 페일백 - DR 앱 중지 + DB 덤프 (FAILBACK_ID 필요)
#   DR_ACTION=failback-finish : 페일백 - nginx 원복 + 정리
# 필요한 환경변수 (aws-bootstrap 의 CodeBuild 프로젝트가 넣어줌)
#   DR_ACTION, DR_PUBLIC_IP, BACKUP_BUCKET, BACKUP_KEY, MONGO_PASSWORD_PARAMETER, ECR_REGISTRY, APP_IMAGES, AWS_REGION
set -euo pipefail

case "${DR_ACTION:-recover}" in
  recover)         SCRIPT=aws-dr/scripts/recover.sh ;;
  failback-export) SCRIPT=aws-dr/scripts/failback-export.sh ;;
  failback-finish) SCRIPT=aws-dr/scripts/failback-finish.sh ;;
  *) echo "알 수 없는 DR_ACTION: '$DR_ACTION'"; exit 1 ;;
esac
echo "DR_ACTION=${DR_ACTION:-recover} ($SCRIPT)"

# Route 53 Secondary IP 가 붙어 있는 인스턴스 = DR 서버 (인스턴스를 다시 만들어도 따라감)
INSTANCE_ID=$(aws ec2 describe-addresses --public-ips "$DR_PUBLIC_IP" \
  --query 'Addresses[0].InstanceId' --output text)
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "$DR_PUBLIC_IP 에 연결된 인스턴스가 없습니다"
  exit 1
fi
echo "DR 서버: $INSTANCE_ID ($DR_PUBLIC_IP)"

# DR 서버에서: recovery.zip 다운로드 -> 압축 해제 -> 스크립트 실행 (명령이 짧아서 SSM 전송 크기 제한과 무관)
SRC_DIR=/opt/wegovy-dr/src
ENV_VARS=$(printf 'SRC_DIR=%q BACKUP_BUCKET=%q BACKUP_KEY=%q MONGO_PASSWORD_PARAMETER=%q ECR_REGISTRY=%q APP_IMAGES=%q FAILBACK_ID=%q AWS_REGION=%q' \
  "$SRC_DIR" "$BACKUP_BUCKET" "$BACKUP_KEY" "$MONGO_PASSWORD_PARAMETER" "$ECR_REGISTRY" "$APP_IMAGES" "${FAILBACK_ID:-}" "$AWS_REGION")
REMOTE_CMD="set -e
rm -rf $SRC_DIR && mkdir -p $SRC_DIR
aws s3 cp --only-show-errors --region $AWS_REGION s3://$BACKUP_BUCKET/recovery.zip $SRC_DIR.zip
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' $SRC_DIR.zip $SRC_DIR
$ENV_VARS bash $SRC_DIR/$SCRIPT"
PARAMS=$(python3 -c 'import json, sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["3600"]}))' "$REMOTE_CMD")

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "wegovy DR ${DR_ACTION:-recover}" \
  --parameters "$PARAMS" \
  --query Command.CommandId --output text)
echo "SSM CommandId: $COMMAND_ID"

# 최대 65분 대기
STATUS=Pending
for _ in $(seq 1 260); do
  sleep 15
  STATUS=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)
  echo "$(date -Is) $STATUS"
  case "$STATUS" in Success|Failed|Cancelled|TimedOut) break ;; esac
done

# SSM 은 출력 끝부분만 돌려줌. 전체 로그는 DR 서버의 /var/log/wegovy-dr.log
echo "----- DR 서버 출력 -----"
aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text || true

[ "$STATUS" = "Success" ]
