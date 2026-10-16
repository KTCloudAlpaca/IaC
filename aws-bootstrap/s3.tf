# 팀이 이미 쓰고 있는 백업 버킷을 그대로 사용 (Terraform 이 만들거나 지우지 않음)
#   backups/full-cluster-backup.tar.gz  최신 백업 (매시간 덮어씀)
#   logs/                               애플리케이션 로그
#   dr-manifests/                       DR 클러스터에 추가로 apply 할 YAML (선택)
#   recovery.zip                        aws-dr/ 압축본 (CodeBuild 소스)
#   terraform-state/aws-dr.tfstate      CodeBuild 가 apply/destroy 할 때 쓰는 state
data "aws_s3_bucket" "dr" {
  bucket = var.bucket_name
}

# aws-dr/ 를 압축해서 recovery.zip 으로 업로드 (내용이 바뀌면 다시 올라감)
data "archive_file" "recovery" {
  type        = "zip"
  source_dir  = "${path.module}/../aws-dr"
  output_path = "${path.module}/.build/recovery.zip"
  excludes = [
    ".terraform",
    ".terraform/**",
    "*.tfstate",
    "*.tfstate.*",
    "*.tfvars",
  ]
}

resource "aws_s3_object" "recovery" {
  bucket = data.aws_s3_bucket.dr.id
  key    = "recovery.zip"
  source = data.archive_file.recovery.output_path
  etag   = data.archive_file.recovery.output_md5
}
