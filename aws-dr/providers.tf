provider "aws" {
  region = var.region

  # 프로젝트 계정이 아니면 plan/apply 단계에서 바로 실패
  allowed_account_ids = ["995342110514"]

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "aws-dr"
    }
  }
}
