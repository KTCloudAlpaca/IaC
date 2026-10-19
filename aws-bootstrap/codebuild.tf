# recovery.zip(= aws-dr/) 을 소스로 받아 DR 서버(EC2Backup)에 SSM Run Command 로 recover.sh 실행
#   장애:   EventBridge 가 시작 (DR_ACTION=recover)
#   테스트: aws codebuild start-build --project-name <이름>
#   페일백: onprem/scripts/failback.sh 가 DR_ACTION=failback-export / failback-finish 로 시작
resource "aws_codebuild_project" "dr" {
  name          = "${var.project}-dr-recovery"
  description   = "온프레 장애 시 DR 서버에서 복구 스크립트 실행"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 75

  # 알람이 여러 번 울려도 빌드는 하나만
  concurrent_build_limit = 1

  # CodeBuild 가 zip 을 내려받아 자동으로 풀고, zip 안의 buildspec.yml 실행
  source {
    type     = "S3"
    location = "${data.aws_s3_bucket.dr.id}/${aws_s3_object.recovery.key}"
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"

    # recover | failback-export | failback-finish (aws-dr/ci/run-on-dr.sh)
    environment_variable {
      name  = "DR_ACTION"
      value = "recover"
    }

    # 이 IP 가 붙어 있는 인스턴스를 DR 서버로 사용
    environment_variable {
      name  = "DR_PUBLIC_IP"
      value = data.aws_eip.dr.public_ip
    }

    environment_variable {
      name  = "BACKUP_BUCKET"
      value = data.aws_s3_bucket.dr.id
    }

    environment_variable {
      name  = "BACKUP_KEY"
      value = var.backup_key
    }

    environment_variable {
      name  = "MONGO_PASSWORD_PARAMETER"
      value = aws_ssm_parameter.mongo_root_password.name
    }

    # 앱 이미지를 받을 ECR 주소와 이미지:태그 목록
    environment_variable {
      name  = "ECR_REGISTRY"
      value = local.ecr_registry
    }

    environment_variable {
      name  = "APP_IMAGES"
      value = join(" ", [for i in var.app_images : "${i}:${var.app_image_tag}"])
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }
}
