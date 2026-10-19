# 앱 이미지 저장소. 온프레에서 빌드한 이미지를 여기에도 push 해두면
# 온프레가 죽어도 DR 서버(EC2Backup)가 받아서 실행할 수 있음
resource "aws_ecr_repository" "app" {
  for_each = toset(var.app_images)

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# 최근 5개 이미지만 보관 (저장 비용 유지)
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

locals {
  # 예: 995342110514.dkr.ecr.ap-northeast-2.amazonaws.com
  ecr_registry = split("/", aws_ecr_repository.app[var.app_images[0]].repository_url)[0]
}
