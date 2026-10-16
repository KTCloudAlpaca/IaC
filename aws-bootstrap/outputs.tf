output "bucket_name" {
  value = data.aws_s3_bucket.dr.id
}

output "codebuild_project_name" {
  value = aws_codebuild_project.dr.name
}

output "heartbeat_alarm_name" {
  value = aws_cloudwatch_metric_alarm.heartbeat.alarm_name
}

output "dr_public_ip" {
  value = aws_eip.dr.public_ip
}

# 온프레 CronJob Secret 에 넣을 값
#   terraform output -raw onprem_access_key_id
#   terraform output -raw onprem_secret_access_key
output "onprem_access_key_id" {
  value = aws_iam_access_key.onprem.id
}

output "onprem_secret_access_key" {
  value     = aws_iam_access_key.onprem.secret
  sensitive = true
}
