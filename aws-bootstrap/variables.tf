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

# ---------- ECR ----------

variable "app_images" {
  type        = map(string)
  description = "DR 서버가 ECR 에서 받을 앱 이미지와 태그 (onprem/app.tf 의 이미지 태그와 같게)"
  default = {
    "launcher-frontend" = "v1"
    "launcher-backend"  = "v3" # v3: /api/dr-ready, v2: /metrics
  }
}

# ---------- 하트비트 / 알람 ----------

variable "heartbeat_alarm_name" {
  type        = string
  description = "팀원이 만든 하트비트 알람 이름 (OK -> ALARM 이 되면 DR 복구 시작)"
  default     = "EC2-trigger-alarm"
}

variable "auto_recovery_enabled" {
  type        = bool
  description = "true 면 알람 OK -> ALARM 시 자동으로 DR 복구 실행. 하트비트가 안정적으로 들어오기 전에는 false"
  default     = false
}

# ---------- Route 53 ----------

variable "dr_public_ip" {
  type        = string
  description = "DR 진입점 EIP (Route 53 Secondary 레코드 값과 같아야 함)"
  default     = "43.200.208.156"
}

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
