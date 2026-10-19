# ---------- ② CodeBuild 서비스 역할 (DR 서버에 SSM Run Command 실행) ----------

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.project}-dr-codebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

data "aws_iam_policy_document" "codebuild" {
  # 빌드 로그
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.codebuild.arn}:*"]
  }

  # recovery.zip 읽기
  statement {
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${data.aws_s3_bucket.dr.arn}/recovery.zip"]
  }

  # DR 서버 찾기 (Route 53 Secondary EIP 가 붙어 있는 인스턴스)
  statement {
    actions   = ["ec2:DescribeAddresses"]
    resources = ["*"]
  }

  # DR 서버에 복구 스크립트 실행
  statement {
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
  }

  statement {
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "dr-run-command"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

# ---------- ③ EventBridge -> CodeBuild StartBuild 역할 ----------

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "${var.project}-dr-events"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events" {
  statement {
    actions   = ["codebuild:StartBuild"]
    resources = [aws_codebuild_project.dr.arn]
  }
}

resource "aws_iam_role_policy" "events" {
  name   = "start-dr-build"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events.json
}
