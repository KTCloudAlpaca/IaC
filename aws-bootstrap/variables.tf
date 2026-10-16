variable "region" {
  type        = string
  description = "DR 환경을 만들 AWS 리전 (Alarm, EventBridge, CodeBuild 모두 같은 리전)"
  default     = "ap-northeast-2"
}

variable "project" {
  type        = string
  description = "리소스 이름 접두사"
  default     = "wegovy"
}

# ---------- S3 / 백업 ----------

variable "bucket_name" {
  type        = string
  description = "팀이 이미 쓰고 있는 백업 버킷 (recovery.zip, aws-dr state 도 여기에 둠)"
  default     = "k8s-hybrid-dr-backup-2026-995342110514-ap-northeast-2-an"
}

variable "backup_key" {
  type        = string
  description = "DR 복구에 쓸 최신 백업 오브젝트 키 (안에 db-data/mongodb.archive 포함)"
  default     = "backups/full-cluster-backup.tar.gz"
}

variable "mongo_root_password" {
  type        = string
  description = "DR MongoDB root 비밀번호 (온프레와 동일하게)"
  sensitive   = true
}

# ---------- 하트비트 / 알람 ----------

variable "heartbeat_namespace" {
  type        = string
  description = "온프레 CronJob이 PutMetricData 할 CloudWatch 네임스페이스"
  default     = "Wegovy/DR"
}

variable "heartbeat_metric_name" {
  type    = string
  default = "Heartbeat"
}

variable "cluster_name" {
  type        = string
  description = "하트비트 메트릭의 Cluster 디멘션 값"
  default     = "onprem"
}

variable "alarm_evaluation_periods" {
  type        = number
  description = "하트비트가 몇 분(1분 단위) 연속 끊기면 장애로 판단할지"
  default     = 3
}

# ---------- CodeBuild ----------

variable "terraform_version" {
  type        = string
  description = "CodeBuild에서 설치할 Terraform 버전 (aws-dr 실행용)"
  default     = "1.16.5"
}

# ---------- Route 53 ----------

variable "enable_route53" {
  type        = bool
  description = "Route 53 헬스체크/Failover 레코드 생성 여부 (도메인이 준비된 경우에만 true)"
  default     = false
}

variable "hosted_zone_name" {
  type        = string
  description = "Route 53 호스팅 영역 이름 (예: example.com)"
  default     = ""
}

variable "record_name" {
  type        = string
  description = "Failover 레코드 이름 (예: app.example.com)"
  default     = ""
}

variable "onprem_public_ip" {
  type        = string
  description = "온프레미스 공인 IP (Primary 레코드 대상)"
  default     = ""
}

variable "health_check_port" {
  type    = number
  default = 80
}

variable "health_check_path" {
  type    = string
  default = "/health"
}
