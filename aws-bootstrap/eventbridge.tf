# 팀원 하트비트 알람(EC2-trigger-alarm)이 OK -> ALARM 으로 바뀌면 CodeBuild 복구 실행
#   하트비트: OnPrem/Kubernetes / Heartbeat / Cluster=onprem-k8s, 2분 동안 없으면 ALARM
#   팀원 알람과 SNS 이메일 설정은 건드리지 않음
# previousState = OK 조건: 데이터 없음(INSUFFICIENT_DATA) -> ALARM 일 때는 복구가 돌지 않게 함
locals {
  heartbeat_alarm_arn = "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${var.heartbeat_alarm_name}"
}

resource "aws_cloudwatch_event_rule" "heartbeat_alarm" {
  name        = "${var.project}-dr-trigger"
  description = "온프레 하트비트 ALARM -> DR CodeBuild 시작"

  # 꺼져 있으면 규칙만 만들어 두고 반응하지 않음 (실수로 DR 이 도는 것 방지)
  state = var.auto_recovery_enabled ? "ENABLED" : "DISABLED"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    resources     = [local.heartbeat_alarm_arn]
    detail = {
      state         = { value = ["ALARM"] }
      previousState = { value = ["OK"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "codebuild" {
  rule     = aws_cloudwatch_event_rule.heartbeat_alarm.name
  arn      = aws_codebuild_project.dr.arn
  role_arn = aws_iam_role.events.arn
}
