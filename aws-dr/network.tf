data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "dr" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project}-dr"
  }
}

resource "aws_internet_gateway" "dr" {
  vpc_id = aws_vpc.dr.id

  tags = {
    Name = "${var.project}-dr"
  }
}

# NAT 없이 퍼블릭 서브넷 하나 (이미지 pull, S3 다운로드용 인터넷 필요)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.dr.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-dr-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.dr.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dr.id
  }

  tags = {
    Name = "${var.project}-dr-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------- Security Group ----------

resource "aws_security_group" "k8s" {
  name        = "${var.project}-dr-k8s"
  description = "DR Kubernetes nodes"
  vpc_id      = aws_vpc.dr.id

  tags = {
    Name = "${var.project}-dr-k8s"
  }
}

# 노드끼리는 전부 허용 (kubelet, flannel VXLAN, NodePort 등)
resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.k8s.id
  referenced_security_group_id = aws_security_group.k8s.id
  ip_protocol                  = "-1"
}

# 서비스 트래픽 (Route 53 헬스체크 포함)
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.k8s.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.k8s.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "apiserver" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.k8s.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.k8s.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
