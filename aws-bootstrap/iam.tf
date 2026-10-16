# ---------- ① 온프레미스용 IAM 유저 (하트비트 전송, 백업/로그 업로드) ----------

resource "aws_iam_user" "onprem" {
  name = "${var.project}-onprem"
}

data "aws_iam_policy_document" "onprem" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.heartbeat_namespace]
    }
  }

  statement {
    actions = ["s3:PutObject"]
    resources = [
      "${data.aws_s3_bucket.dr.arn}/backups/*",
      "${data.aws_s3_bucket.dr.arn}/logs/*",
    ]
  }
}

resource "aws_iam_user_policy" "onprem" {
  name   = "onprem-heartbeat-backup"
  user   = aws_iam_user.onprem.name
  policy = data.aws_iam_policy_document.onprem.json
}

# secret 이 state 에 평문으로 저장됨 -> state 파일 절대 커밋 금지
resource "aws_iam_access_key" "onprem" {
  user = aws_iam_user.onprem.name
}

# ---------- ② CodeBuild 서비스 역할 (aws-dr Terraform 실행) ----------

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

  # aws-dr state 읽기/쓰기 (use_lockfile 이 .tflock 파일을 만들고 지움)
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${data.aws_s3_bucket.dr.arn}/terraform-state/*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.dr.arn]
  }

  # VPC / Subnet / SG / EC2 / EIP 연결 생성·삭제
  statement {
    actions   = ["ec2:*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # EC2 에 인스턴스 프로파일 붙이기
  statement {
    actions = [
      "iam:GetRole",
      "iam:GetInstanceProfile",
    ]
    resources = [
      aws_iam_role.ec2.arn,
      aws_iam_instance_profile.ec2.arn,
    ]
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ec2.arn]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "dr-terraform"
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

# ---------- ④ DR EC2 인스턴스 프로파일 (S3 백업 읽기, 비밀번호 조회) ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-dr-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "ec2" {
  # 최신 백업 + 추가 매니페스트 읽기
  statement {
    actions = ["s3:GetObject"]
    resources = [
      "${data.aws_s3_bucket.dr.arn}/${var.backup_key}",
      "${data.aws_s3_bucket.dr.arn}/dr-manifests/*",
    ]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.dr.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["dr-manifests/*"]
    }
  }

  # MongoDB root 비밀번호
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.mongo_root_password.arn]
  }
}

resource "aws_iam_role_policy" "ec2" {
  name   = "read-backup"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2.json
}

# SSH 없이 Session Manager 로 user-data 디버깅
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-dr-ec2"
  role = aws_iam_role.ec2.name
}
