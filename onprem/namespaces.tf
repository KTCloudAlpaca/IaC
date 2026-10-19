locals {
  namespaces = toset(["ai", "app", "db", "monitor"])
}

# 이미 kubectl로 만들어둔 네임스페이스를 Terraform 관리로 가져오기
# 첫 apply 성공 후에는 이 import 블록을 지워도 됨
import {
  for_each = local.namespaces
  to       = kubernetes_namespace_v1.this[each.key]
  id       = each.key
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.namespaces

  metadata {
    name = each.key
  }

  # 실수로 destroy 해도 네임스페이스가 삭제되지 않도록 막음
  lifecycle {
    prevent_destroy = true
  }

}