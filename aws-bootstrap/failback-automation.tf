# Add this file to the existing aws-bootstrap/ directory.
# It intentionally uses the existing data.aws_s3_bucket.dr and var.* values from IaC.

variable "enable_automatic_failback" {
  description = "If true, run the failback workflow after the on-prem heartbeat alarm transitions ALARM -> OK. Keep false until fully tested."
  type        = bool
  default     = false
}

variable "failback_initial_active_environment" {
  description = "Seed active-environment only if the object does not exist yet. Set to aws-dr if installing this add-on during an active DR event."
  type        = string
  default     = "onprem"
  validation {
    condition     = contains(["onprem", "aws-dr"], var.failback_initial_active_environment)
    error_message = "failback_initial_active_environment must be onprem or aws-dr."
  }
}

variable "failback_wait_seconds" {
  description = "Maximum time CodeBuild waits for the on-prem restore Job to report success."
  type        = number
  default     = 10800
}

variable "failback_master_tag_value" {
  description = "Name tag value of the AWS DR master instance. Must match aws-dr/compute.tf."
  type        = string
  default     = "wegovy-dr-master"
}

variable "failback_workload_label_selector" {
  description = "Label selector of application writers that must be paused before final dump. Do not label MongoDB itself."
  type        = string
  default     = "dr-failback-managed=true"
}

# Seed the active-environment marker once. Runtime scripts update it; Terraform must not revert it.
resource "aws_s3_object" "failback_active_environment" {
  bucket  = data.aws_s3_bucket.dr.id
  key     = "failback/control/active-environment"
  content = "${var.failback_initial_active_environment}\n"
  etag    = md5("${var.failback_initial_active_environment}\n")

  lifecycle {
    ignore_changes = [content, etag]
  }
}

# Package the CodeBuild buildspec separately from recovery.zip (which contains aws-dr Terraform).
data "archive_file" "failback_build_source" {
  type        = "zip"
  source_dir  = "${path.module}/failback-build"
  output_path = "${path.module}/.build/failback-codebuild.zip"
  excludes    = ["*.tfstate", "*.tfvars", ".terraform/**"]
}

resource "aws_s3_object" "failback_build_source" {
  bucket = data.aws_s3_bucket.dr.id
  key    = "failback-codebuild.zip"
  source = data.archive_file.failback_build_source.output_path
  etag   = data.archive_file.failback_build_source.output_md5
}

resource "aws_cloudwatch_log_group" "failback_codebuild" {
  name              = "/aws/codebuild/${var.project}-dr-failback"
  retention_in_days = 30
}

data "aws_caller_identity" "failback" {}

data "aws_iam_policy_document" "failback_codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "failback_codebuild" {
  name               = "${var.project}-dr-failback-codebuild"
  assume_role_policy = data.aws_iam_policy_document.failback_codebuild_assume.json
}

data "aws_iam_policy_document" "failback_codebuild" {
  statement {
    sid       = "WriteBuildLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.failback_codebuild.arn}:*"]
  }

  statement {
    sid       = "ReadBuildSource"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${data.aws_s3_bucket.dr.arn}/${aws_s3_object.failback_build_source.key}"]
  }

  statement {
    sid       = "GetSourceBucketMetadata"
    actions   = ["s3:GetBucketAcl", "s3:GetBucketLocation"]
    resources = [data.aws_s3_bucket.dr.arn]
  }

  statement {
    sid       = "ReadFailbackStatusObjects"
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.dr.arn}/failback/status/*"]
  }

  statement {
    sid       = "ListOnlyFailbackStatusPrefix"
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.dr.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["failback/status/*"]
    }
  }

  statement {
    sid       = "SendRunCommandToDrMaster"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }

  statement {
    sid     = "SendRunCommandOnlyToTaggedDrMaster"
    actions = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.failback.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = [var.failback_master_tag_value]
    }
  }

  statement {
    sid = "PollRunCommand"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:ListCommands",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "failback_codebuild" {
  name   = "${var.project}-dr-failback-codebuild"
  role   = aws_iam_role.failback_codebuild.id
  policy = data.aws_iam_policy_document.failback_codebuild.json
}

resource "aws_codebuild_project" "failback" {
  name                   = "${var.project}-dr-failback"
  description            = "Pause AWS DR writers, publish final MongoDB backup, and wait for on-prem restore acknowledgement"
  service_role           = aws_iam_role.failback_codebuild.arn
  build_timeout           = 240
  concurrent_build_limit = 1

  source {
    type      = "S3"
    location  = "${data.aws_s3_bucket.dr.id}/${aws_s3_object.failback_build_source.key}"
    buildspec = "buildspec.yml"
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "FAILBACK_BUCKET"
      value = data.aws_s3_bucket.dr.id
    }
    environment_variable {
      name  = "FAILBACK_PREFIX"
      value = "failback"
    }
    environment_variable {
      name  = "DR_MASTER_TAG_VALUE"
      value = var.failback_master_tag_value
    }
    environment_variable {
      name  = "FAILBACK_WAIT_SECONDS"
      value = tostring(var.failback_wait_seconds)
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.failback_codebuild.name
    }
  }

  depends_on = [aws_s3_object.failback_active_environment]
}

# Least-privilege extension for the existing EC2 role used by aws-dr instances.
data "aws_iam_policy_document" "failback_dr_ec2" {
  statement {
    sid = "PublishFailbackBackupAndStatus"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      "${data.aws_s3_bucket.dr.arn}/failback/*",
    ]
  }
  statement {
    sid       = "SetActiveEnvironment"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${data.aws_s3_bucket.dr.arn}/failback/control/active-environment"]
  }
}

resource "aws_iam_role_policy" "failback_dr_ec2" {
  name   = "${var.project}-dr-failback-publish"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.failback_dr_ec2.json
}

# Existing on-prem heartbeat principal can pull a published final backup, upload rollback data/status,
# and update the active-environment marker. Scope is restricted to the failback prefix.
data "aws_iam_policy_document" "failback_onprem" {
  statement {
    sid       = "ReadFailbackTriggerAndBackup"
    actions   = ["s3:GetObject"]
    resources = [
      "${data.aws_s3_bucket.dr.arn}/failback/current/*",
      "${data.aws_s3_bucket.dr.arn}/failback/runs/*",
      "${data.aws_s3_bucket.dr.arn}/failback/control/active-environment",
    ]
  }
  statement {
    sid       = "WriteFailbackRollbackAndStatus"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = [
      "${data.aws_s3_bucket.dr.arn}/failback/rollback/*",
      "${data.aws_s3_bucket.dr.arn}/failback/status/*",
      "${data.aws_s3_bucket.dr.arn}/failback/control/active-environment",
    ]
  }
}

resource "aws_iam_user_policy" "failback_onprem" {
  name   = "${var.project}-onprem-failback"
  user   = aws_iam_user.onprem.name
  policy = data.aws_iam_policy_document.failback_onprem.json
}

# Optional trigger: heartbeat transition ALARM -> OK. Disabled by default because a transient
# heartbeat recovery should not automatically pause AWS writes without an operational review.
resource "aws_cloudwatch_event_rule" "automatic_failback" {
  count       = var.enable_automatic_failback ? 1 : 0
  name        = "${var.project}-dr-failback-trigger"
  description = "Optional automatic failback after on-prem heartbeat alarm recovers"
  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    resources     = [aws_cloudwatch_metric_alarm.heartbeat.arn]
    detail = {
      state         = { value = ["OK"] }
      previousState = { value = ["ALARM"] }
    }
  })
}

data "aws_iam_policy_document" "failback_events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "failback_events" {
  name               = "${var.project}-dr-failback-events"
  assume_role_policy = data.aws_iam_policy_document.failback_events_assume.json
}

data "aws_iam_policy_document" "failback_events" {
  statement {
    actions   = ["codebuild:StartBuild"]
    resources = [aws_codebuild_project.failback.arn]
  }
}

resource "aws_iam_role_policy" "failback_events" {
  name   = "${var.project}-dr-failback-start-build"
  role   = aws_iam_role.failback_events.id
  policy = data.aws_iam_policy_document.failback_events.json
}

resource "aws_cloudwatch_event_target" "automatic_failback" {
  count     = var.enable_automatic_failback ? 1 : 0
  rule      = aws_cloudwatch_event_rule.automatic_failback[0].name
  arn       = aws_codebuild_project.failback.arn
  role_arn  = aws_iam_role.failback_events.arn
}

output "failback_codebuild_project_name" {
  description = "Manually start this CodeBuild project to begin failback."
  value       = aws_codebuild_project.failback.name
}
