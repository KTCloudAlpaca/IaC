# 팀원이 kubectl로 만든 MongoDB를 Terraform 관리로 가져오기
import {
  for_each = local.import_once
  to       = kubernetes_stateful_set_v1.mongodb
  id       = "db/mongodb"
}

import {
  for_each = local.import_once
  to       = kubernetes_service_v1.mongodb
  id       = "db/mongodb"
}

resource "kubernetes_stateful_set_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = kubernetes_namespace_v1.this["db"].metadata[0].name
    labels    = { app = "mongodb" }
  }

  spec {
    replicas     = 1
    service_name = "mongodb"

    selector {
      match_labels = { app = "mongodb" }
    }

    template {
      metadata {
        labels = { app = "mongodb" }
      }

      spec {
        # 클러스터에 명시되지 않은 값 (Terraform 기본값 true 와 달라서 맞춰 둠)
        automount_service_account_token = false
        enable_service_links            = false

        container {
          name  = "mongodb"
          image = "mongo:6.0"

          port {
            container_port = 27017
          }

          env {
            name  = "MONGO_INITDB_ROOT_USERNAME"
            value = "root"
          }
          env {
            name  = "MONGO_INITDB_ROOT_PASSWORD"
            value = var.mongo_root_password
          }

          volume_mount {
            name       = "mongodb-data"
            mount_path = "/data/db"
          }
          volume_mount {
            name       = "mongodb-logs"
            mount_path = "/var/log/mongodb"
          }
        }

        # NFS PVC (storage.tf)
        volume {
          name = "mongodb-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.mongodb_data.metadata[0].name
          }
        }
        volume {
          name = "mongodb-logs"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.mongodb_logs.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = kubernetes_namespace_v1.this["db"].metadata[0].name
  }

  spec {
    type     = "NodePort"
    selector = { app = "mongodb" }

    port {
      port        = 27017
      target_port = 27017
      node_port   = 30017
    }
  }
}
# 팀원이 kubectl로 만든 mongo-express(웹 DB 관리 화면) 가져오기
import {
  for_each = local.import_once
  to       = kubernetes_deployment_v1.mongo_express
  id       = "db/mongo-express"
}

import {
  for_each = local.import_once
  to       = kubernetes_service_v1.mongo_express
  id       = "db/mongo-express"
}

resource "kubernetes_deployment_v1" "mongo_express" {
  metadata {
    name      = "mongo-express"
    namespace = kubernetes_namespace_v1.this["db"].metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "mongo-express" }
    }

    template {
      metadata {
        labels = { app = "mongo-express" }
        # kubectl rollout restart 기록 (지우면 파드가 재시작됨)
        annotations = { "kubectl.kubernetes.io/restartedAt" = "2026-10-08T17:30:42+09:00" }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false

        container {
          name              = "mongo-express"
          image             = "mongo-express:latest"
          image_pull_policy = "Always"

          port {
            container_port = 8081
          }

          env {
            name  = "ME_CONFIG_MONGODB_SERVER"
            value = "mongodb.db.svc.cluster.local." # 끝의 "." : app.tf backend-secret 주석 참고
          }
          env {
            name  = "ME_CONFIG_MONGODB_PORT"
            value = "27017"
          }
          env {
            name  = "ME_CONFIG_MONGODB_ENABLE_ADMIN"
            value = "true"
          }
          env {
            name  = "ME_CONFIG_MONGODB_ADMINUSERNAME"
            value = "root"
          }
          env {
            name  = "ME_CONFIG_MONGODB_ADMINPASSWORD"
            value = var.mongo_root_password
          }
          env {
            name  = "ME_CONFIG_MONGODB_AUTH_DATABASE"
            value = "admin"
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "mongo_express" {
  metadata {
    name      = "mongo-express"
    namespace = kubernetes_namespace_v1.this["db"].metadata[0].name
  }

  spec {
    type     = "NodePort"
    selector = { app = "mongo-express" }

    port {
      name        = "http"
      port        = 8081
      target_port = 8081
      node_port   = 30081
    }
  }
}
