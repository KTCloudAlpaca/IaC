output "bucket_name" {
  value = data.aws_s3_bucket.dr.id
}

output "codebuild_project_name" {
  value = aws_codebuild_project.dr.name
}

output "heartbeat_alarm_name" {
  value = var.heartbeat_alarm_name
}

output "dr_public_ip" {
  value = data.aws_eip.dr.public_ip
}

# 앱 담당이 이미지를 push 할 주소
output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}
