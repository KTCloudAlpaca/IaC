terraform {
  required_version = ">= 1.7.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30.0, < 3.0.0"
    }
  }
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

variable "kubeconfig_path" {
  description = "Kubeconfig for the on-premises cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "namespace" {
  description = "Namespace for the failback worker and MongoDB service."
  type        = string
  default     = "db"
}

variable "backup_bucket" {
  description = "Existing S3 bucket already used by the team's DR project."
  type        = string
  default     = "k8s-hybrid-dr-backup-2026-995342110514-ap-northeast-2-an"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "failback_prefix" {
  type    = string
  default = "failback"
}

variable "aws_access_key_id" {
  description = "Dedicated/limited IAM access key. Sensitive; do not commit tfvars."
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "Dedicated/limited IAM secret key. Sensitive; do not commit tfvars."
  type        = string
  sensitive   = true
}

variable "mongo_root_password" {
  description = "Same root password as the on-prem MongoDB StatefulSet. Sensitive; do not commit tfvars."
  type        = string
  sensitive   = true
}

variable "mongo_host" {
  description = "In-cluster MongoDB service DNS name."
  type        = string
  default     = "mongodb.db.svc.cluster.local"
}

variable "mongo_image" {
  description = "Use the same pinned image/version family as the on-prem MongoDB deployment."
  type        = string
  default     = "mongo:6.0"
}

variable "aws_cli_image" {
  description = "Pin to an approved AWS CLI v2 image digest before production use."
  type        = string
  default     = "public.ecr.aws/aws-cli/aws-cli:2"
}

variable "alpine_image" {
  description = "Pin this utility image to an approved digest before production use."
  type        = string
  default     = "alpine:3.22"
}

variable "kubectl_version" {
  description = "Must be compatible with the on-prem Kubernetes API server."
  type        = string
  default     = "v1.36.3"
}

variable "failback_workload_namespaces" {
  description = "Namespaces in which write-capable Deployments/CronJobs are label-managed for failback."
  type        = list(string)
  default     = ["app", "ai"]
}

variable "state_storage_class" {
  description = "RWX StorageClass used for small failback state files. Confirm this class exists before apply."
  type        = string
  default     = "nfs-prometheus"
}

variable "work_storage_class" {
  description = "RWX StorageClass used to stage large backup/rollback files. Prefer a dedicated NFS StorageClass."
  type        = string
  default     = "nfs-prometheus"
}

variable "state_storage_size" {
  type    = string
  default = "1Gi"
}

variable "work_storage_size" {
  description = "Must exceed the final AWS backup plus the on-prem rollback archive and extraction overhead."
  type        = string
  default     = "30Gi"
}

variable "cron_schedule" {
  description = "Poll S3 for a new failback trigger."
  type        = string
  default     = "*/1 * * * *"
}

variable "initial_onprem_ready" {
  description = "Treat the existing on-prem primary as ready until S3 says AWS DR is active. Set false until the readiness gate is deliberately enabled/tested."
  type        = bool
  default     = true
}

variable "readiness_node_port" {
  description = "NodePort monitored by Route 53 for /dr-ready. Open this port to Route 53 health checkers at the on-prem edge."
  type        = number
  default     = 30082
}

resource "kubernetes_secret_v1" "failback_credentials" {
  metadata {
    name      = "failback-agent-credentials"
    namespace = var.namespace
  }
  type = "Opaque"
  data = {
    aws_access_key_id     = var.aws_access_key_id
    aws_secret_access_key = var.aws_secret_access_key
    mongo_root_password   = var.mongo_root_password
  }
}

resource "kubernetes_persistent_volume_claim_v1" "failback_state" {
  metadata {
    name      = "failback-state"
    namespace = var.namespace
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = var.state_storage_class
    resources {
      requests = { storage = var.state_storage_size }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "failback_work" {
  metadata {
    name      = "failback-work"
    namespace = var.namespace
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = var.work_storage_class
    resources {
      requests = { storage = var.work_storage_size }
    }
  }
}

resource "kubernetes_config_map_v1" "failback_scripts" {
  metadata {
    name      = "failback-agent-scripts"
    namespace = var.namespace
  }
  data = {
    "fetch-backup.sh"       = file("${path.module}/scripts/fetch-backup.sh")
    "pause-workloads.sh"    = file("${path.module}/scripts/pause-workloads.sh")
    "snapshot-onprem.sh"    = file("${path.module}/scripts/snapshot-onprem.sh")
    "upload-rollback.sh"    = file("${path.module}/scripts/upload-rollback.sh")
    "restore.sh"            = file("${path.module}/scripts/restore.sh")
    "report-status.sh"      = file("${path.module}/scripts/report-status.sh")
    "readiness-watcher.sh"  = file("${path.module}/scripts/readiness-watcher.sh")
    "nginx.conf"            = <<-NGINX
      server {
        listen 8080;
        server_name _;
        location = /dr-ready {
          if (-f /usr/share/nginx/html/READY) { return 200 "ready\\n"; }
          return 503 "not-ready\\n";
        }
        location / { return 404; }
      }
    NGINX
  }
}

resource "kubernetes_service_account_v1" "failback_agent" {
  metadata {
    name      = "failback-agent"
    namespace = var.namespace
  }
  automount_service_account_token = true
}

# The agent may stop/resume only explicitly labelled application writers, and only in the configured namespaces.
resource "kubernetes_role_v1" "failback_workloads" {
  for_each = toset(var.failback_workload_namespaces)
  metadata {
    name      = "failback-agent-workloads"
    namespace = each.value
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "deployments/scale"]
    verbs      = ["get", "list", "patch", "update", "watch"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs", "jobs"]
    verbs      = ["get", "list", "patch", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "failback_workloads" {
  for_each = toset(var.failback_workload_namespaces)
  metadata {
    name      = "failback-agent-workloads"
    namespace = each.value
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.failback_workloads[each.value].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.failback_agent.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_cron_job_v1" "failback_restore" {
  metadata {
    name      = "failback-restore"
    namespace = var.namespace
    labels = {
      app = "failback-restore"
    }
  }
  spec {
    schedule                      = var.cron_schedule
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 120
    successful_jobs_history_limit = 2
    failed_jobs_history_limit     = 5
    job_template {
      metadata {
        labels = { app = "failback-restore" }
      }
      spec {
        backoff_limit           = 0
        active_deadline_seconds = 14400
        template {
          metadata {
            labels = { app = "failback-restore" }
          }
          spec {
            service_account_name            = kubernetes_service_account_v1.failback_agent.metadata[0].name
            automount_service_account_token = true
            restart_policy                  = "Never"

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.failback_scripts.metadata[0].name
                default_mode = 493
              }
            }
            volume {
              name = "work"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim_v1.failback_work.metadata[0].name
              }
            }
            volume {
              name = "state"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim_v1.failback_state.metadata[0].name
              }
            }

            init_container {
              name    = "fetch-backup"
              image   = var.aws_cli_image
              command = ["/bin/sh", "-ec", "sh /scripts/fetch-backup.sh"]
              env {
                name  = "AWS_DEFAULT_REGION"
                value = var.aws_region
              }
              env {
                name  = "BACKUP_BUCKET"
                value = var.backup_bucket
              }
              env {
                name  = "FAILBACK_PREFIX"
                value = var.failback_prefix
              }
              env {
                name = "AWS_ACCESS_KEY_ID"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_access_key_id"
                  }
                }
              }
              env {
                name = "AWS_SECRET_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_secret_access_key"
                  }
                }
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "state"
                mount_path = "/state"
              }
            }

            init_container {
              name    = "pause-workloads"
              image   = var.alpine_image
              command = ["/bin/sh", "-ec", "sh /scripts/pause-workloads.sh"]
              env {
                name  = "KUBECTL_VERSION"
                value = var.kubectl_version
              }
              env {
                name  = "FAILBACK_WORKLOAD_NAMESPACES"
                value = join(",", var.failback_workload_namespaces)
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "state"
                mount_path = "/state"
              }
            }

            init_container {
              name    = "snapshot-onprem"
              image   = var.mongo_image
              command = ["/bin/sh", "-ec", "sh /scripts/snapshot-onprem.sh"]
              env {
                name  = "MONGO_HOST"
                value = var.mongo_host
              }
              env {
                name = "MONGO_ROOT_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "mongo_root_password"
                  }
                }
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "state"
                mount_path = "/state"
              }
            }

            init_container {
              name    = "upload-rollback"
              image   = var.aws_cli_image
              command = ["/bin/sh", "-ec", "sh /scripts/upload-rollback.sh"]
              env {
                name  = "AWS_DEFAULT_REGION"
                value = var.aws_region
              }
              env {
                name  = "BACKUP_BUCKET"
                value = var.backup_bucket
              }
              env {
                name  = "FAILBACK_PREFIX"
                value = var.failback_prefix
              }
              env {
                name = "AWS_ACCESS_KEY_ID"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_access_key_id"
                  }
                }
              }
              env {
                name = "AWS_SECRET_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_secret_access_key"
                  }
                }
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "state"
                mount_path = "/state"
              }
            }

            container {
              name    = "restore-db"
              image   = var.mongo_image
              command = ["/bin/sh", "-ec", "sh /scripts/restore.sh"]
              env {
                name  = "MONGO_HOST"
                value = var.mongo_host
              }
              env {
                name = "MONGO_ROOT_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "mongo_root_password"
                  }
                }
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "state"
                mount_path = "/state"
              }
            }

            # Sidecar waits for restore-db, resumes workloads only after DB checks pass, then marks active environment=onprem.
            container {
              name    = "report-status"
              image   = var.aws_cli_image
              command = ["/bin/sh", "-ec", "sh /scripts/report-status.sh"]
              env {
                name  = "AWS_DEFAULT_REGION"
                value = var.aws_region
              }
              env {
                name  = "BACKUP_BUCKET"
                value = var.backup_bucket
              }
              env {
                name  = "FAILBACK_PREFIX"
                value = var.failback_prefix
              }
              env {
                name = "AWS_ACCESS_KEY_ID"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_access_key_id"
                  }
                }
              }
              env {
                name = "AWS_SECRET_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_secret_access_key"
                  }
                }
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "state"
                mount_path = "/state"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_role_binding_v1.failback_workloads,
    kubernetes_persistent_volume_claim_v1.failback_state,
    kubernetes_persistent_volume_claim_v1.failback_work,
  ]
}

# Route 53 gate: a small NodePort endpoint returns 200 only while S3 says On-Prem is the active environment.
resource "kubernetes_deployment_v1" "failback_readiness_gate" {
  metadata {
    name      = "failback-readiness-gate"
    namespace = var.namespace
    labels    = { app = "failback-readiness-gate" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "failback-readiness-gate" }
    }
    template {
      metadata {
        labels = { app = "failback-readiness-gate" }
      }
      spec {
        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map_v1.failback_scripts.metadata[0].name
            items {
              key  = "nginx.conf"
              path = "default.conf"
            }
          }
        }
        volume {
          name = "ready-files"
          empty_dir {}
        }
        volume {
          name = "state"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.failback_state.metadata[0].name
          }
        }
        volume {
          name = "credentials"
          secret {
            secret_name = kubernetes_secret_v1.failback_credentials.metadata[0].name
          }
        }
        init_container {
          name    = "initial-readiness-sync"
          image   = var.aws_cli_image
          command = ["/bin/sh", "-ec", "ACTIVE=$(aws s3 cp s3://${var.backup_bucket}/${var.failback_prefix}/control/active-environment - --region ${var.aws_region} 2>/dev/null | tr -d '\\r\\n' || true); if [ \"$ACTIVE\" = \"onprem\" ] && { [ \"${var.initial_onprem_ready}\" = \"true\" ] || [ -f /state/last_successful_run_id ]; }; then touch /shared/READY; else rm -f /shared/READY; fi"]
          env {
                name  = "AWS_DEFAULT_REGION"
                value = var.aws_region
              }
          env {
                name = "AWS_ACCESS_KEY_ID"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_access_key_id"
                  }
                }
              }
          env {
                name = "AWS_SECRET_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_secret_access_key"
                  }
                }
              }
          volume_mount {
                name       = "ready-files"
                mount_path = "/shared"
              }
          volume_mount {
                name       = "state"
                mount_path = "/state"
              }
        }
        container {
          name    = "nginx"
          image   = "nginx:1.27-alpine"
          command = ["nginx", "-g", "daemon off;"]
          port {
            name           = "http"
            container_port = 8080
          }
          volume_mount {
                name       = "scripts"
                mount_path = "/etc/nginx/conf.d"
                read_only  = true
              }
          volume_mount {
                name       = "ready-files"
                mount_path = "/usr/share/nginx/html"
                read_only  = true
              }
          readiness_probe {
            http_get {
              path = "/dr-ready"
              port = 8080
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }
        }
        container {
          name    = "active-environment-watcher"
          image   = var.aws_cli_image
          command = ["/bin/sh", "-ec", "sh /scripts/readiness-watcher.sh"]
          env {
                name  = "AWS_DEFAULT_REGION"
                value = var.aws_region
              }
          env {
                name  = "BACKUP_BUCKET"
                value = var.backup_bucket
              }
          env {
                name  = "FAILBACK_PREFIX"
                value = var.failback_prefix
              }
          env {
                name  = "INITIAL_ONPREM_READY"
                value = tostring(var.initial_onprem_ready)
              }
          env {
                name = "AWS_ACCESS_KEY_ID"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_access_key_id"
                  }
                }
              }
          env {
                name = "AWS_SECRET_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.failback_credentials.metadata[0].name
                    key  = "aws_secret_access_key"
                  }
                }
              }
          volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
          volume_mount {
                name       = "ready-files"
                mount_path = "/shared"
              }
          volume_mount {
                name       = "state"
                mount_path = "/state"
              }
        }
      }
    }
  }
  depends_on = [kubernetes_persistent_volume_claim_v1.failback_state]
}

resource "kubernetes_service_v1" "failback_readiness_gate" {
  metadata {
    name      = "failback-readiness-gate"
    namespace = var.namespace
    labels    = { app = "failback-readiness-gate" }
  }
  spec {
    type = "NodePort"
    selector = { app = "failback-readiness-gate" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      node_port   = var.readiness_node_port
    }
  }
}

output "readiness_url_path" {
  value       = "/dr-ready"
  description = "Configure the Route 53 primary health check to this path and the NodePort specified by readiness_node_port."
}

output "failback_schedule" {
  value = var.cron_schedule
}
