provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}

locals {
  # import 블록용: 온프레(import_existing=true)일 때만 가져오기 실행
  import_once = var.import_existing ? toset(["onprem"]) : toset([])
}
