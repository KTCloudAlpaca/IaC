# 팀원이 helm으로 설치한 kube-prometheus-stack(mymonitor)을 Terraform 관리로 가져오기
# 첫 apply 성공 후에는 이 import 블록을 지워도 됨
import {
  to = helm_release.monitoring
  id = "monitor/mymonitor"
}

# Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics
resource "helm_release" "monitoring" {
  name       = "mymonitor"
  namespace  = kubernetes_namespace_v1.this["monitor"].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "92.3.0"

  values = [file("${path.module}/values/prometheus.yaml")]
}

# 팀원이 kubectl로 만든 Prometheus용 NFS StorageClass 가져오기
import {
  to = kubernetes_storage_class_v1.nfs_prometheus
  id = "nfs-prometheus"
}

import {
  to = kubernetes_storage_class_v1.nfs_prometheus_logs
  id = "nfs-prometheus-logs"
}

# 메트릭 저장용 (master: /data/prometheus)
resource "kubernetes_storage_class_v1" "nfs_prometheus" {
  metadata {
    name = "nfs-prometheus"
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    server = "10.120.0.140"
    share  = "/data/prometheus"
  }
}

# 로그 저장용 (master: /data/prometheus-logs)
resource "kubernetes_storage_class_v1" "nfs_prometheus_logs" {
  metadata {
    name = "nfs-prometheus-logs"
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    server = "10.120.0.140"
    share  = "/data/prometheus-logs"
  }
}

# 팀원이 kubectl로 만든 로그 저장용 PVC 가져오기
# (nfs-prometheus-test PVC는 연결 테스트용이라 제외)
import {
  to = kubernetes_persistent_volume_claim_v1.prometheus_logs
  id = "monitor/prometheus-logs-pvc"
}

resource "kubernetes_persistent_volume_claim_v1" "prometheus_logs" {
  metadata {
    name      = "prometheus-logs-pvc"
    namespace = kubernetes_namespace_v1.this["monitor"].metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.nfs_prometheus_logs.metadata[0].name

    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
}
