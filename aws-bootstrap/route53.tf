# DR 진입점 공인 IP. 미리 잡아두고 aws-dr 이 EC2 에 연결만 함
# -> Secondary 레코드를 장애 전에 만들어 둘 수 있음
resource "aws_eip" "dr" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-dr-ingress"
  }
}

# ---------- Failover (enable_route53 = true 일 때만) ----------

data "aws_route53_zone" "this" {
  count = var.enable_route53 ? 1 : 0
  name  = var.hosted_zone_name
}

resource "aws_route53_health_check" "primary" {
  count = var.enable_route53 ? 1 : 0

  ip_address        = var.onprem_public_ip
  port              = var.health_check_port
  type              = "HTTP"
  resource_path     = var.health_check_path
  request_interval  = 10
  failure_threshold = 3

  tags = {
    Name = "${var.project}-onprem"
  }
}

resource "aws_route53_health_check" "secondary" {
  count = var.enable_route53 ? 1 : 0

  ip_address        = aws_eip.dr.public_ip
  port              = var.health_check_port
  type              = "HTTP"
  resource_path     = var.health_check_path
  request_interval  = 10
  failure_threshold = 3

  tags = {
    Name = "${var.project}-aws-dr"
  }
}

resource "aws_route53_record" "primary" {
  count = var.enable_route53 ? 1 : 0

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = var.record_name
  type            = "A"
  ttl             = 60
  records         = [var.onprem_public_ip]
  set_identifier  = "onprem"
  health_check_id = aws_route53_health_check.primary[0].id

  failover_routing_policy {
    type = "PRIMARY"
  }
}

resource "aws_route53_record" "secondary" {
  count = var.enable_route53 ? 1 : 0

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = var.record_name
  type            = "A"
  ttl             = 60
  records         = [aws_eip.dr.public_ip]
  set_identifier  = "aws-dr"
  health_check_id = aws_route53_health_check.secondary[0].id

  failover_routing_policy {
    type = "SECONDARY"
  }
}
