# recovery.zip 을 소스로 받아 aws-dr Terraform 을 apply / destroy
#   장애:   EventBridge 가 TF_ACTION=apply 로 시작
#   페일백: aws codebuild start-build --project-name <이름> \
#             --environment-variables-override name=TF_ACTION,value=destroy,type=PLAINTEXT
resource "aws_codebuild_project" "dr" {
  name          = "${var.project}-dr-recovery"
  description   = "온프레 장애 시 aws-dr Terraform 실행"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  # 알람이 여러 번 울려도 빌드는 하나만
  concurrent_build_limit = 1

  # CodeBuild 가 zip 을 내려받아 자동으로 풀어줌
  source {
    type      = "S3"
    location  = "${data.aws_s3_bucket.dr.id}/${aws_s3_object.recovery.key}"
    buildspec = <<-EOT
      version: 0.2
      phases:
        install:
          commands:
            - curl -fsSL -o /tmp/terraform.zip https://releases.hashicorp.com/terraform/$${TF_VERSION}/terraform_$${TF_VERSION}_linux_amd64.zip
            - unzip -o /tmp/terraform.zip -d /usr/local/bin
            - terraform version
        build:
          commands:
            - echo "TF_ACTION=$${TF_ACTION}"
            - terraform init -input=false -backend-config="bucket=$${TF_STATE_BUCKET}" -backend-config="key=$${TF_STATE_KEY}" -backend-config="region=$${AWS_REGION}" -backend-config="use_lockfile=true"
            - terraform $${TF_ACTION} -auto-approve -input=false
    EOT
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"

    environment_variable {
      name  = "TF_ACTION"
      value = "apply"
    }

    environment_variable {
      name  = "TF_VERSION"
      value = var.terraform_version
    }

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = data.aws_s3_bucket.dr.id
    }

    environment_variable {
      name  = "TF_STATE_KEY"
      value = "terraform-state/aws-dr.tfstate"
    }

    # aws-dr 의 variable 로 그대로 들어감
    environment_variable {
      name  = "TF_VAR_region"
      value = var.region
    }

    environment_variable {
      name  = "TF_VAR_backup_bucket"
      value = data.aws_s3_bucket.dr.id
    }

    environment_variable {
      name  = "TF_VAR_backup_key"
      value = var.backup_key
    }

    environment_variable {
      name  = "TF_VAR_mongo_password_parameter"
      value = aws_ssm_parameter.mongo_root_password.name
    }

    environment_variable {
      name  = "TF_VAR_instance_profile_name"
      value = aws_iam_instance_profile.ec2.name
    }

    environment_variable {
      name  = "TF_VAR_eip_allocation_id"
      value = aws_eip.dr.allocation_id
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }
}
