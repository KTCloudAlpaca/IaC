output "master_public_ip" {
  value = data.aws_eip.dr.public_ip
}

output "master_instance_id" {
  value = aws_instance.master.id
}

output "worker_instance_ids" {
  value = aws_instance.worker[*].id
}

# 부팅/복구 진행 상황 확인
#   aws ssm start-session --target <master_instance_id>
#   sudo tail -f /var/log/dr-bootstrap.log
output "ssm_session_command" {
  value = "aws ssm start-session --target ${aws_instance.master.id}"
}
