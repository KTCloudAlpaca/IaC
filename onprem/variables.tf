variable "mongo_root_password" {
  description = "MongoDB root 비밀번호"
  type        = string
  sensitive   = true
}

# ---------- 환경별 값 ----------
# 기본값 = 온프레미스. 백업 EC2 는 env/backup.tfvars 로 덮어씀
#   온프레:  terraform workspace select default && terraform apply
#   백업:    terraform workspace select backup  && terraform apply -var-file=env/backup.tfvars

variable "kubeconfig_path" {
  description = "대상 클러스터 kubeconfig"
  type        = string
  default     = "~/.kube/config"
}

variable "import_existing" {
  description = "true: 이미 있는 리소스를 가져옴(온프레). false: 빈 클러스터에 새로 만듦(백업 EC2)"
  type        = bool
  default     = true
}

variable "nfs_server" {
  description = "NFS 서버 주소 (온프레: master, 백업: EC2 자신)"
  type        = string
  default     = "10.120.0.140"
}

variable "app_node_selector" {
  description = "앱(frontend/backend)을 띄울 노드 (온프레는 worker 노드 고정, 백업은 단일 노드라 비움)"
  type        = map(string)
  default     = { "kubernetes.io/hostname" = "worker" }
}

variable "enable_metallb" {
  description = "MetalLB 설치 여부 (AWS VPC 에서는 L2 방식이 동작하지 않아 백업 EC2 는 false)"
  type        = bool
  default     = true
}

variable "metallb_addresses" {
  description = "MetalLB 가 LoadBalancer 에 나눠줄 IP 대역"
  type        = list(string)
  default     = ["10.120.0.150-10.120.0.159"]
}

variable "istioctl_path" {
  description = "Istio 설치에 쓸 istioctl (온프레 master 기준)"
  type        = string
  default     = "~/istio-1.31.1/bin/istioctl"
}
