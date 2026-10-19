# NFS 스토리지: CSI 드라이버 + MongoDB 용 고정 PV/PVC
# NFS 서버 자체(/etc/exports, /data/*)는 scripts/install-k8s.sh 가 준비

import {
  for_each = local.import_once
  to       = helm_release.csi_driver_nfs
  id       = "kube-system/csi-driver-nfs"
}

resource "helm_release" "csi_driver_nfs" {
  name       = "csi-driver-nfs"
  namespace  = "kube-system"
  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  version    = "4.13.4"
}

# ---------- MongoDB 데이터 / 로그 (NFS 서버의 /data/mongodb, /data/mongodb-logs) ----------

import {
  for_each = local.import_once
  to       = kubernetes_persistent_volume_v1.mongodb_data
  id       = "mongodb-data"
}

import {
  for_each = local.import_once
  to       = kubernetes_persistent_volume_v1.mongodb_logs
  id       = "mongodb-log"
}

import {
  for_each = local.import_once
  to       = kubernetes_persistent_volume_claim_v1.mongodb_data
  id       = "db/mongodb-data-nfs-pvc"
}

import {
  for_each = local.import_once
  to       = kubernetes_persistent_volume_claim_v1.mongodb_logs
  id       = "db/mongodb-logs-nfs-pvc"
}

resource "kubernetes_persistent_volume_v1" "mongodb_data" {
  metadata {
    name = "mongodb-data"
  }

  spec {
    capacity                         = { storage = "5Gi" }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"

    persistent_volume_source {
      nfs {
        server = var.nfs_server
        path   = "/data/mongodb"
      }
    }

    # 이 PVC 에만 묶이도록 (다른 PVC 가 가져가지 않게)
    claim_ref {
      namespace = "db"
      name      = "mongodb-data-nfs-pvc"
    }
  }
}

resource "kubernetes_persistent_volume_v1" "mongodb_logs" {
  metadata {
    name = "mongodb-log"
  }

  spec {
    capacity                         = { storage = "2Gi" }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"

    persistent_volume_source {
      nfs {
        server = var.nfs_server
        path   = "/data/mongodb-logs"
      }
    }

    claim_ref {
      namespace = "db"
      name      = "mongodb-logs-nfs-pvc"
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "mongodb_data" {
  metadata {
    name      = "mongodb-data-nfs-pvc"
    namespace = kubernetes_namespace_v1.this["db"].metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume_v1.mongodb_data.metadata[0].name

    resources {
      requests = { storage = "5Gi" }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "mongodb_logs" {
  metadata {
    name      = "mongodb-logs-nfs-pvc"
    namespace = kubernetes_namespace_v1.this["db"].metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume_v1.mongodb_logs.metadata[0].name

    resources {
      requests = { storage = "2Gi" }
    }
  }
}
