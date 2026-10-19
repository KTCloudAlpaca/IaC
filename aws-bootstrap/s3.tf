# 팀이 이미 쓰고 있는 백업 버킷을 그대로 사용 (Terraform 이 만들거나 지우지 않음)
#   backups/full-cluster-backup.tar.gz  최신 백업 (매시간 덮어씀)
#   logs/                               애플리케이션 로그
#   recovery.zip                        aws-dr/ + onprem/ 압축본 (CodeBuild 소스: 복구 스크립트 + DR 환경 Terraform)
data "aws_s3_bucket" "dr" {
  bucket = var.bucket_name
}

# aws-dr/(복구 스크립트) + onprem/(DR 환경을 만들 Terraform) 을 recovery.zip 으로 업로드
# 장애 시 DR 서버가 이 zip 의 onprem 코드로 온프레와 같은 환경을 만듦 (내용이 바뀌면 다시 올라감)
# 비밀값(terraform.tfvars)과 state, 이 폴더(aws-bootstrap)는 제외
data "archive_file" "recovery" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/.build/recovery.zip"
  excludes = [
    ".git/**",
    ".gitignore",
    "README.md",
    "aws-bootstrap/**",
    "onprem/.terraform/**",
    "onprem/terraform.tfstate.d/**",
    "onprem/terraform.tfstate",
    "onprem/terraform.tfstate.backup",
    "onprem/terraform.tfvars",
  ]
}

resource "aws_s3_object" "recovery" {
  bucket = data.aws_s3_bucket.dr.id
  key    = "recovery.zip"
  source = data.archive_file.recovery.output_path
  etag   = data.archive_file.recovery.output_md5
}

