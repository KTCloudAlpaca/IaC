# 클러스터 애드온: Istio(demo 프로필), main-gateway, MetalLB
# 온프레는 팀원이 이미 설치함 -> import_existing=true 면 건너뜀
# 빈 클러스터(백업 EC2)에서는 온프레와 같은 버전/설정으로 설치
#   (Istio 는 istioctl 로 설치되어 helm 릴리스가 없고, Gateway/MetalLB 설정은 CRD 라서
#    Terraform kubernetes provider 대신 실행하는 쪽 kubectl/istioctl 로 적용)

locals {
  install_addons = var.import_existing ? 0 : 1
  kube_env       = { KUBECONFIG = pathexpand(var.kubeconfig_path) }
}

# ---------- Istio 1.31.1 (온프레와 같은 demo 프로필: ingress + egress gateway) ----------
resource "terraform_data" "istio" {
  count            = local.install_addons
  triggers_replace = ["1.31.1", "demo"]

  provisioner "local-exec" {
    command     = "${pathexpand(var.istioctl_path)} install --set profile=demo -y"
    environment = local.kube_env
  }

  # Istio gateway 는 NodePort 를 무작위로 받음 -> 고정 NodePort(30080/30017/30081/30486/31230) 서비스를 먼저 만들어 충돌 방지
  depends_on = [
    kubernetes_namespace_v1.this,
    kubernetes_service_v1.frontend,
    kubernetes_service_v1.mongodb,
    kubernetes_service_v1.mongo_express,
    helm_release.monitoring, # Grafana 30486, Prometheus 31230
  ]
}

resource "terraform_data" "istio_main_gateway" {
  count            = local.install_addons
  triggers_replace = [filemd5("${path.module}/manifests/istio-main-gateway.yaml")]

  provisioner "local-exec" {
    command     = "kubectl apply -f ${path.module}/manifests/istio-main-gateway.yaml"
    environment = local.kube_env
  }

  depends_on = [terraform_data.istio]
}

# ---------- MetalLB v0.14.8 ----------
resource "terraform_data" "metallb" {
  count            = var.enable_metallb ? local.install_addons : 0
  triggers_replace = ["v0.14.8"]

  provisioner "local-exec" {
    command     = <<-EOT
      kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
      kubectl -n metallb-system wait --for=condition=Available deployment/controller --timeout=300s
    EOT
    environment = local.kube_env
  }
}

resource "terraform_data" "metallb_pool" {
  count            = var.enable_metallb ? local.install_addons : 0
  triggers_replace = [var.metallb_addresses]

  provisioner "local-exec" {
    command     = "kubectl apply -f - <<'YAML'\n${templatefile("${path.module}/manifests/metallb-pool.yaml.tftpl", { addresses = var.metallb_addresses })}\nYAML"
    environment = local.kube_env
  }

  depends_on = [terraform_data.metallb]
}
