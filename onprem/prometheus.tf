# 팀원이 helm으로 설치한 kube-prometheus-stack(mymonitor)을 Terraform 관리로 가져오기
# 첫 apply 성공 후에는 이 import 블록을 지워도 됨
import {
  for_each = local.import_once
  to       = helm_release.monitoring
  id       = "monitor/mymonitor"
}

# Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics
resource "helm_release" "monitoring" {
  name       = "mymonitor"
  namespace  = kubernetes_namespace_v1.this["monitor"].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "92.3.0"

  values = [file("${path.module}/values/prometheus.yaml")]

  # 빈 클러스터에서는 메트릭 저장소(NFS StorageClass)가 먼저 있어야 함
  depends_on = [kubernetes_storage_class_v1.nfs_prometheus]
}

# 팀원이 kubectl로 만든 Prometheus용 NFS StorageClass 가져오기
import {
  for_each = local.import_once
  to       = kubernetes_storage_class_v1.nfs_prometheus
  id       = "nfs-prometheus"
}

import {
  for_each = local.import_once
  to       = kubernetes_storage_class_v1.nfs_prometheus_logs
  id       = "nfs-prometheus-logs"
}

# 메트릭 저장용 (NFS 서버: /data/prometheus)
resource "kubernetes_storage_class_v1" "nfs_prometheus" {
  depends_on = [helm_release.csi_driver_nfs]

  metadata {
    name = "nfs-prometheus"
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    server = var.nfs_server
    share  = "/data/prometheus"
  }
}

# 로그 저장용 (NFS 서버: /data/prometheus-logs)
resource "kubernetes_storage_class_v1" "nfs_prometheus_logs" {
  metadata {
    name = "nfs-prometheus-logs"
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    server = var.nfs_server
    share  = "/data/prometheus-logs"
  }
}

# 팀원이 kubectl로 만든 로그 저장용 PVC 가져오기
# (nfs-prometheus-test PVC는 연결 테스트용이라 제외)
import {
  for_each = local.import_once
  to       = kubernetes_persistent_volume_claim_v1.prometheus_logs
  id       = "monitor/prometheus-logs-pvc"
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

# backend 앱 메트릭 수집용 ServiceMonitor (Prometheus CRD 라서 Helm 설치 후 kubectl 로 적용)
resource "terraform_data" "servicemonitor_backend" {
  triggers_replace = [filemd5("${path.module}/manifests/servicemonitor-backend.yaml")]

  provisioner "local-exec" {
    command     = "kubectl apply -f ${path.module}/manifests/servicemonitor-backend.yaml"
    environment = { KUBECONFIG = pathexpand(var.kubeconfig_path) }
  }

  depends_on = [helm_release.monitoring, kubernetes_service_v1.backend]
}
