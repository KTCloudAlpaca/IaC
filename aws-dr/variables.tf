variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "project" {
  type    = string
  default = "wegovy"
}

# ---------- aws-bootstrap 이 CodeBuild 환경변수(TF_VAR_*)로 넘겨주는 값 ----------

variable "backup_bucket" {
  type        = string
  description = "백업 버킷 이름"
}

variable "backup_key" {
  type        = string
  description = "복구에 쓸 최신 백업 오브젝트 키"
}

variable "mongo_password_parameter" {
  type        = string
  description = "MongoDB root 비밀번호가 들어 있는 SSM 파라미터 이름"
}

variable "instance_profile_name" {
  type        = string
  description = "EC2 인스턴스 프로파일 (S3 백업 읽기, SSM 조회)"
}

variable "eip_allocation_id" {
  type        = string
  description = "미리 잡아둔 DR 진입점 EIP (master 에 연결)"
}

# ---------- 클러스터 ----------

variable "kubernetes_version" {
  type        = string
  description = "pkgs.k8s.io 저장소 버전 (온프레와 맞춤)"
  default     = "1.36"
}

variable "flannel_version" {
  type    = string
  default = "v0.28.9"
}

variable "local_path_provisioner_version" {
  type    = string
  default = "v0.0.30"
}

variable "master_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "worker_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "worker_count" {
  type        = number
  description = "워커 노드 수 (0 이면 master 에 파드도 띄움)"
  default     = 1
}

# ---------- 네트워크 ----------

variable "vpc_cidr" {
  type        = string
  description = "온프레(10.120.0.0/16), 파드(10.244.0.0/16), 서비스(10.96.0.0/12) 와 겹치지 않게"
  default     = "10.50.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.50.1.0/24"
}

variable "admin_cidrs" {
  type        = list(string)
  description = "kube-apiserver(6443) 에 접근 허용할 IP 대역. 비우면 외부 접근 막힘 (SSM 으로 접속)"
  default     = []
}
