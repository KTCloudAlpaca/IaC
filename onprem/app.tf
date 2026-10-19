# 앱 담당이 kubectl로 배포한 frontend / backend 가져오기
# DR 쪽 같은 구성은 aws-dr/manifests/app.yaml (이미지만 ECR)
import {
  to = kubernetes_secret_v1.backend
  id = "app/backend-secret"
}

import {
  to = kubernetes_deployment_v1.backend
  id = "app/backend"
}

import {
  to = kubernetes_service_v1.backend
  id = "app/backend"
}

import {
  to = kubernetes_deployment_v1.frontend
  id = "app/frontend"
}

import {
  to = kubernetes_service_v1.frontend
  id = "app/frontend"
}

# backend 가 쓰는 MongoDB 접속 정보
resource "kubernetes_secret_v1" "backend" {
  metadata {
    name      = "backend-secret"
    namespace = kubernetes_namespace_v1.this["app"].metadata[0].name
  }

  data = {
    MONGODB_URI = "mongodb://root:${var.mongo_root_password}@mongodb.db.svc.cluster.local:27017/launcher?authSource=admin"
  }
}

resource "kubernetes_deployment_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace_v1.this["app"].metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "backend" }
    }

    template {
      metadata {
        labels = { app = "backend" }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false
        node_selector                   = { "kubernetes.io/hostname" = "worker" }

        container {
          name              = "backend"
          image             = "launcher-backend:v1"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 5000
          }

          env {
            name  = "PORT"
            value = "5000"
          }
          env {
            name = "MONGODB_URI"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.backend.metadata[0].name
                key  = "MONGODB_URI"
              }
            }
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = 5000
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = 5000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace_v1.this["app"].metadata[0].name
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "backend" }

    port {
      port        = 5000
      target_port = 5000
    }
  }
}

resource "kubernetes_deployment_v1" "frontend" {
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace_v1.this["app"].metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "frontend" }
    }

    template {
      metadata {
        labels = { app = "frontend" }
      }

      spec {
        automount_service_account_token = false
        enable_service_links            = false
        node_selector                   = { "kubernetes.io/hostname" = "worker" }

        container {
          name              = "frontend"
          image             = "launcher-frontend:v1"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 80
          }

          env {
            name  = "BACKEND_URL"
            value = "http://backend:5000"
          }

          resources {
            requests = { cpu = "50m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "64Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            period_seconds = 5
          }
        }
      }
    }
  }
}

# Route 53 Primary 헬스체크가 중계 서버를 거쳐 이 NodePort 의 /api/health 를 확인함
resource "kubernetes_service_v1" "frontend" {
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace_v1.this["app"].metadata[0].name
  }

  spec {
    type     = "NodePort"
    selector = { app = "frontend" }

    port {
      port        = 80
      target_port = 80
      node_port   = 30080
    }
  }
}
