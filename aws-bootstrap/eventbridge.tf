# 하트비트 알람이 OK -> ALARM 으로 바뀌면 CodeBuild 복구 실행
# previousState = OK 조건: 처음 만들 때 INSUFFICIENT_DATA -> ALARM 으로 바로 복구가 도는 걸 막음
resource "aws_cloudwatch_event_rule" "heartbeat_alarm" {
  name        = "${var.project}-dr-trigger"
  description = "온프레 하트비트 ALARM -> DR CodeBuild 시작"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    resources     = [aws_cloudwatch_metric_alarm.heartbeat.arn]
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

  # StartBuild 파라미터로 전달됨
  input = jsonencode({
    environmentVariablesOverride = [
      { name = "TF_ACTION", value = "apply", type = "PLAINTEXT" },
    ]
  })
}
