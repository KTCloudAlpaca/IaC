# DR EC2 가 부팅할 때 읽어가는 MongoDB root 비밀번호
# user-data 에 평문으로 넣지 않기 위해 SSM Parameter Store 에 보관
resource "aws_ssm_parameter" "mongo_root_password" {
  name  = "/${var.project}/dr/mongo-root-password"
  type  = "SecureString"
  value = var.mongo_root_password
}
