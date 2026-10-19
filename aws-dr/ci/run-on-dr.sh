#!/bin/bash
# CodeBuild 에서 실행: DR 서버(EC2Backup)에 SSM Run Command 로 recover.sh 를 보내고 끝날 때까지 기다림
# 필요한 환경변수 (aws-bootstrap 의 CodeBuild 프로젝트가 넣어줌)
#   DR_PUBLIC_IP, BACKUP_BUCKET, BACKUP_KEY, MONGO_PASSWORD_PARAMETER, ECR_REGISTRY, AWS_REGION
set -euo pipefail

SCRIPT=scripts/recover.sh

# Route 53 Secondary IP 가 붙어 있는 인스턴스 = DR 서버 (인스턴스를 다시 만들어도 따라감)
INSTANCE_ID=$(aws ec2 describe-addresses --public-ips "$DR_PUBLIC_IP" \
  --query 'Addresses[0].InstanceId' --output text)
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "$DR_PUBLIC_IP 에 연결된 인스턴스가 없습니다"
  exit 1
fi
echo "DR 서버: $INSTANCE_ID ($DR_PUBLIC_IP)"

# 스크립트를 base64 로 넘겨서 원격에서 그대로 실행
ENV_VARS=$(printf 'BACKUP_BUCKET=%q BACKUP_KEY=%q MONGO_PASSWORD_PARAMETER=%q ECR_REGISTRY=%q AWS_REGION=%q' \
  "$BACKUP_BUCKET" "$BACKUP_KEY" "$MONGO_PASSWORD_PARAMETER" "$ECR_REGISTRY" "$AWS_REGION")
REMOTE_CMD="echo $(base64 -w0 "$SCRIPT") | base64 -d > /tmp/wegovy-dr.sh && $ENV_VARS bash /tmp/wegovy-dr.sh"
PARAMS=$(python3 -c 'import json, sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": ["3600"]}))' "$REMOTE_CMD")

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "wegovy DR recover" \
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
