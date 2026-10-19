# 하트비트 알람은 팀원이 만든 EC2-trigger-alarm 을 사용 (eventbridge.tf 에서 참조만 함)

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${var.project}-dr-recovery"
  retention_in_days = 30
}
