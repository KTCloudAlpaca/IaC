terraform {
  required_version = ">= 1.10.0"

  # bucket / key / region / use_lockfile 은 CodeBuild 가 init 할 때 -backend-config 로 넣어줌
  # 로컬에서 테스트할 때:
  #   terraform init -backend-config="bucket=<버킷>" -backend-config="key=terraform-state/aws-dr.tfstate" \
  #                  -backend-config="region=ap-northeast-2" -backend-config="use_lockfile=true"
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
