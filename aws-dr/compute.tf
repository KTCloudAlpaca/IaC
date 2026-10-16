data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_eip" "dr" {
  id = var.eip_allocation_id
}

# master / worker 가 미리 같은 토큰을 알고 있으면 join 정보를 따로 전달할 필요가 없음
# 형식: [a-z0-9]{6}.[a-z0-9]{16}
resource "random_string" "token_id" {
  length  = 6
  special = false
  upper   = false
}

resource "random_string" "token_secret" {
  length  = 16
  special = false
  upper   = false
}

locals {
  kubeadm_token = "${random_string.token_id.result}.${random_string.token_secret.result}"
  common_script = file("${path.module}/templates/common.sh")
}

resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.master_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k8s.id]
  iam_instance_profile   = var.instance_profile_name

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/master.sh.tftpl", {
    common                         = local.common_script
    kubernetes_version             = var.kubernetes_version
    kubeadm_token                  = local.kubeadm_token
    public_ip                      = data.aws_eip.dr.public_ip
    flannel_version                = var.flannel_version
    local_path_provisioner_version = var.local_path_provisioner_version
    untaint_master                 = var.worker_count == 0
    region                         = var.region
    backup_bucket                  = var.backup_bucket
    backup_key                     = var.backup_key
    mongo_password_parameter       = var.mongo_password_parameter
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = "${var.project}-dr-master"
    Role = "master"
  }
}

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k8s.id]
  iam_instance_profile   = var.instance_profile_name

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/worker.sh.tftpl", {
    common             = local.common_script
    kubernetes_version = var.kubernetes_version
    kubeadm_token      = local.kubeadm_token
    master_ip          = aws_instance.master.private_ip
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = "${var.project}-dr-worker${count.index + 1}"
    Role = "worker"
  }
}

# 미리 잡아둔 EIP 를 master 에 연결 -> Route 53 Secondary 가 바로 이쪽을 가리킴
resource "aws_eip_association" "master" {
  allocation_id = var.eip_allocation_id
  instance_id   = aws_instance.master.id
}
