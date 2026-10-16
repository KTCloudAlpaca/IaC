# 팀원이 kubectl로 만든 MongoDB를 Terraform 관리로 가져오기
import {
  to = kubernetes_stateful_set_v1.mongodb
  id = "db/mongodb"
}

import {
  to = kubernetes_service_v1.mongodb
  id = "db/mongodb"
}

resource "kubernetes_stateful_set_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = kubernetes_namespace_v1.this["db"].metadata[0].name
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
        container {
          name  = "mongodb"
          image = "mongo:6.0"
          args  = ["--logpath", "/var/log/mongodb/mongod.log", "--logappend"]

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

        # 팀원이 만든 NFS PVC를 그대로 사용
        volume {
          name = "mongodb-data"
          persistent_volume_claim {
            claim_name = "mongodb-data-nfs-pvc"
          }
        }
        volume {
          name = "mongodb-logs"
          persistent_volume_claim {
            claim_name = "mongodb-logs-nfs-pvc"
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