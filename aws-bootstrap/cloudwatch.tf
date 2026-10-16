# 온프레 CronJob 이 1분마다 보내는 하트비트가 N분 연속 안 들어오면 ALARM
#   aws cloudwatch put-metric-data --namespace Wegovy/DR --metric-name Heartbeat \
#     --dimensions Cluster=onprem --value 1
resource "aws_cloudwatch_metric_alarm" "heartbeat" {
  alarm_name        = "${var.project}-onprem-heartbeat"
  alarm_description = "온프레미스 Kubernetes 하트비트 끊김 -> EventBridge -> CodeBuild DR 복구"

  namespace   = var.heartbeat_namespace
  metric_name = var.heartbeat_metric_name
  dimensions = {
    Cluster = var.cluster_name
  }

  statistic           = "SampleCount"
  period              = 60
  evaluation_periods  = var.alarm_evaluation_periods
  datapoints_to_alarm = var.alarm_evaluation_periods
  comparison_operator = "LessThanThreshold"
  threshold           = 1

  # 데이터가 안 들어오는 것 자체가 장애
  treat_missing_data = "breaching"
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${var.project}-dr-recovery"
  retention_in_days = 30
}
