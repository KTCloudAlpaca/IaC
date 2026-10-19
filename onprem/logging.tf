# 팀원이 kubectl로 만든 Prometheus 로그 수집기(fluent-bit DaemonSet) 가져오기
# Prometheus 파드 로그를 prometheus-logs-pvc(NFS) 에 파일로 저장
import {
  for_each = local.import_once
  to       = kubernetes_config_map_v1.log_collector
  id       = "monitor/prometheus-log-collector-config"
}

import {
  for_each = local.import_once
  to       = kubernetes_daemon_set_v1.log_collector
  id       = "monitor/prometheus-log-collector"
}

resource "kubernetes_config_map_v1" "log_collector" {
  metadata {
    name      = "prometheus-log-collector-config"
    namespace = kubernetes_namespace_v1.this["monitor"].metadata[0].name
  }

  data = {
    "fluent-bit.conf" = file("${path.module}/values/fluent-bit.conf")
  }
}

resource "kubernetes_daemon_set_v1" "log_collector" {
  metadata {
    name      = "prometheus-log-collector"
    namespace = kubernetes_namespace_v1.this["monitor"].metadata[0].name
  }

  spec {
    selector {
      match_labels = { app = "prometheus-log-collector" }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 1
      }
    }

    template {
      metadata {
        labels = { app = "prometheus-log-collector" }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false

        toleration {
          operator = "Exists"
        }

        container {
          name              = "fluent-bit"
          image             = "cr.fluentbit.io/fluent/fluent-bit:3.2.10"
          image_pull_policy = "IfNotPresent"

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                api_version = "v1"
                field_path  = "spec.nodeName"
              }
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/fluent-bit/etc/fluent-bit.conf"
            sub_path   = "fluent-bit.conf"
            read_only  = true
          }
          volume_mount {
            name       = "container-logs"
            mount_path = "/var/log/containers"
            read_only  = true
          }
          volume_mount {
            name       = "pod-logs"
            mount_path = "/var/log/pods"
            read_only  = true
          }
          volume_mount {
            name       = "log-storage"
            mount_path = "/logs"
          }
          volume_mount {
            name       = "tail-db"
            mount_path = "/tail-db"
          }
        }

        volume {
          name = "config"
          config_map {
            name         = kubernetes_config_map_v1.log_collector.metadata[0].name
            default_mode = "0644"
          }
        }
        volume {
          name = "container-logs"
          host_path {
            path = "/var/log/containers"
            type = "Directory"
          }
        }
        volume {
          name = "pod-logs"
          host_path {
            path = "/var/log/pods"
            type = "Directory"
          }
        }
        volume {
          name = "log-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.prometheus_logs.metadata[0].name
          }
        }
        volume {
          name = "tail-db"
          empty_dir {}
        }
      }
    }
  }
}
