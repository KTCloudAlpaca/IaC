# server-wegovy-terraform

server-wegovy 프로젝트의 Kubernetes 인프라를 관리하는 Terraform 코드입니다.
팀원이 `kubectl` / `helm`으로 직접 만든 리소스를 `import` 블록으로 가져와 Terraform으로 관리합니다.

## 관리 대상

| 파일 | 리소스 | 설명 |
| --- | --- | --- |
| [namespaces.tf](namespaces.tf) | `kubernetes_namespace_v1.this` | 네임스페이스 `ai`, `app`, `db`, `monitor` (`prevent_destroy` 적용) |
| [database.tf](database.tf) | `kubernetes_stateful_set_v1.mongodb`<br>`kubernetes_service_v1.mongodb` | MongoDB 6.0 StatefulSet (`db` 네임스페이스), NodePort `30017` |
| [prometheus.tf](prometheus.tf) | `helm_release.monitoring` | kube-prometheus-stack `92.3.0` (릴리스명 `mymonitor`, `monitor` 네임스페이스) |
| | `kubernetes_storage_class_v1.nfs_prometheus` | 메트릭 저장용 NFS StorageClass (`10.120.0.140:/data/prometheus`) |
| | `kubernetes_storage_class_v1.nfs_prometheus_logs` | 로그 저장용 NFS StorageClass (`10.120.0.140:/data/prometheus-logs`) |
| | `kubernetes_persistent_volume_claim_v1.prometheus_logs` | 로그 저장용 PVC `prometheus-logs-pvc` (2Gi, RWX) |

Helm values는 [values/prometheus.yaml](values/prometheus.yaml)에서 관리합니다.

> MongoDB가 사용하는 PVC(`mongodb-data-nfs-pvc`, `mongodb-logs-nfs-pvc`)는 Terraform 관리 대상이 아니며, 이미 클러스터에 존재해야 합니다.

## 요구 사항

- Terraform `>= 1.7.0`
- Provider: `hashicorp/kubernetes >= 2.30`, `hashicorp/helm >= 3.0`
- 클러스터에 접근 가능한 `~/.kube/config`
- 클러스터에 NFS CSI 드라이버(`nfs.csi.k8s.io`) 설치

## 사용 방법

### 1. 변수 설정

`terraform.tfvars` 파일을 만들고 MongoDB root 비밀번호를 넣습니다.

```hcl
mongo_root_password = "<비밀번호>"
```

> `*.tfvars`는 `.gitignore`에 포함되어 있으니 절대 커밋하지 마세요.

### 2. 실행

```bash
terraform init
terraform plan
terraform apply
```

첫 `apply`에서 기존 리소스가 state로 import 됩니다. import가 끝난 뒤에는 각 파일의 `import` 블록을 지워도 됩니다.

## 변수

| 이름 | 타입 | 설명 |
| --- | --- | --- |
| `mongo_root_password` | `string` (sensitive) | MongoDB root 비밀번호 |

## 주의 사항

- **state 파일에 비밀번호가 평문으로 저장됩니다.** `*.tfstate`, `*.tfplan`은 커밋하지 않습니다.
- 네임스페이스는 `prevent_destroy`가 걸려 있어 `terraform destroy`로 삭제되지 않습니다.
- NFS StorageClass는 `reclaim_policy = "Retain"`이라 PVC를 지워도 데이터가 남습니다.
- Prometheus는 아직 영구 저장소가 연결되지 않아 Pod 재시작 시 메트릭이 사라집니다. 이후 `nfs-prometheus` StorageClass로 연결할 예정입니다.
