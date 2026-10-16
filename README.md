# server-wegovy-terraform

온프레미스 Kubernetes 장애를 감지해 AWS에 DR 클러스터를 자동으로 띄우는 **Hybrid Cloud DR** 프로젝트의 Terraform 코드입니다.

## 구조

| 폴더 | 역할 | 실행 주체 | state |
| --- | --- | --- | --- |
| [onprem/](onprem/) | 온프레미스 Kubernetes 리소스 (네임스페이스, MongoDB, Prometheus) | 사람 | 로컬 |
| [aws-bootstrap/](aws-bootstrap/) | 사전 준비: 알람, EventBridge, CodeBuild, IAM, EIP 등 (1회 apply) | 사람 | 로컬 |
| [aws-dr/](aws-dr/) | DR 환경: VPC, EC2, Kubernetes, DB 복원 | **CodeBuild만** | S3 |

세 폴더는 state가 따로라서 서로 영향을 주지 않습니다. Terraform 명령은 항상 **각 폴더 안에서** 실행합니다.

## 자동 복구 흐름

```
[온프레 하트비트 CronJob] --1분마다 PutMetricData--> CloudWatch 메트릭 (Wegovy/DR / Heartbeat)
        │ 3분 연속 안 들어옴
        ▼
CloudWatch Alarm (OK -> ALARM)
        ▼
EventBridge 규칙 --StartBuild (TF_ACTION=apply)--> CodeBuild
        ▼
S3 recovery.zip(= aws-dr/) 자동 압축 해제 -> terraform init (S3 backend) -> terraform apply
        ▼
EC2 user-data: kubeadm -> MongoDB 배포 -> S3 최신 백업 다운로드 -> mongorestore
        ▼
Route 53 Secondary 헬스체크 통과 -> 트래픽 AWS로 전환
```

## S3 버킷

팀이 이미 쓰고 있는 `k8s-hybrid-dr-backup-2026-995342110514-ap-northeast-2-an` 버킷을 사용합니다. Terraform은 이 버킷을 만들거나 지우지 않습니다.

| 경로 | 내용 | 올리는 주체 |
| --- | --- | --- |
| `backups/full-cluster-backup.tar.gz` | 최신 백업 (매시간 덮어씀). **DR 복원에 사용** | 팀원 백업 작업 |
| `backups/full-cluster-backup-YYYYMMDD-HHMM.tar.gz` | 시간별 백업 | 팀원 백업 작업 |
| `recovery.zip` | `aws-dr/` 압축본 (CodeBuild 소스) | aws-bootstrap apply |
| `terraform-state/aws-dr.tfstate` | aws-dr state | CodeBuild |
| `dr-manifests/` | DR 클러스터에 추가로 apply 할 YAML (선택) | 사람 |

---

## onprem

팀원이 `kubectl` / `helm`으로 직접 만든 리소스를 `import` 블록으로 가져와 Terraform으로 관리합니다.

| 파일 | 리소스 | 설명 |
| --- | --- | --- |
| [namespaces.tf](onprem/namespaces.tf) | `kubernetes_namespace_v1.this` | 네임스페이스 `ai`, `app`, `db`, `monitor` (`prevent_destroy` 적용) |
| [database.tf](onprem/database.tf) | `kubernetes_stateful_set_v1.mongodb`<br>`kubernetes_service_v1.mongodb` | MongoDB 6.0 StatefulSet (`db` 네임스페이스), NodePort `30017` |
| [prometheus.tf](onprem/prometheus.tf) | `helm_release.monitoring` | kube-prometheus-stack `92.3.0` (릴리스명 `mymonitor`, `monitor` 네임스페이스) |
| | `kubernetes_storage_class_v1.nfs_prometheus` | 메트릭 저장용 NFS StorageClass (`10.120.0.140:/data/prometheus`) |
| | `kubernetes_storage_class_v1.nfs_prometheus_logs` | 로그 저장용 NFS StorageClass (`10.120.0.140:/data/prometheus-logs`) |
| | `kubernetes_persistent_volume_claim_v1.prometheus_logs` | 로그 저장용 PVC `prometheus-logs-pvc` (2Gi, RWX) |

Helm values는 [values/prometheus.yaml](onprem/values/prometheus.yaml)에서 관리합니다.

> MongoDB가 사용하는 PVC(`mongodb-data-nfs-pvc`, `mongodb-logs-nfs-pvc`)는 Terraform 관리 대상이 아니며, 이미 클러스터에 존재해야 합니다.

**요구 사항**

- Terraform `>= 1.7.0`
- Provider: `hashicorp/kubernetes >= 2.30`, `hashicorp/helm >= 3.0`
- 클러스터에 접근 가능한 `~/.kube/config`
- 클러스터에 NFS CSI 드라이버(`nfs.csi.k8s.io`) 설치

**실행**

`onprem/terraform.tfvars`:

```hcl
mongo_root_password = "<비밀번호>"
```

```bash
cd onprem
terraform init
terraform plan
terraform apply
```

첫 `apply`에서 기존 리소스가 state로 import 됩니다. import가 끝난 뒤에는 각 파일의 `import` 블록을 지워도 됩니다.

---

## aws-bootstrap

장애 감지부터 CodeBuild 실행까지 연결하는 사전 준비 리소스입니다. 사람이 **한 번** apply 합니다.

| 파일 | 리소스 |
| --- | --- |
| [s3.tf](aws-bootstrap/s3.tf) | 기존 버킷 참조, `aws-dr/` → `recovery.zip` 압축/업로드 (내용이 바뀌면 다시 올라감) |
| [cloudwatch.tf](aws-bootstrap/cloudwatch.tf) | 하트비트 알람 (`treat_missing_data = breaching`), CodeBuild 로그 그룹 |
| [eventbridge.tf](aws-bootstrap/eventbridge.tf) | 알람 `OK -> ALARM` 시 CodeBuild 실행 |
| [codebuild.tf](aws-bootstrap/codebuild.tf) | `wegovy-dr-recovery` 프로젝트 (Terraform 설치 → init → `apply`/`destroy`), 동시 실행 1개 |
| [iam.tf](aws-bootstrap/iam.tf) | 온프레용 유저/키, CodeBuild·EventBridge·EC2 역할, 인스턴스 프로파일 |
| [ssm.tf](aws-bootstrap/ssm.tf) | MongoDB root 비밀번호 (SecureString) |
| [route53.tf](aws-bootstrap/route53.tf) | DR 진입점 EIP (미리 할당), Failover 레코드/헬스체크 (`enable_route53 = true` 일 때만) |

**실행**

`aws-bootstrap/terraform.tfvars`:

```hcl
mongo_root_password = "<온프레와 같은 비밀번호>"

# 도메인이 준비되면
# enable_route53   = true
# hosted_zone_name = "example.com"
# record_name      = "app.example.com"
# onprem_public_ip = "x.x.x.x"
```

```bash
cd aws-bootstrap
export AWS_PROFILE=<본인 프로필>
terraform init
terraform plan
terraform apply
```

- provider에 `allowed_account_ids = ["995342110514"]`가 걸려 있어서 다른 계정으로 실행하면 바로 실패합니다.
- `aws-dr/`을 수정했으면 여기서 다시 `apply` 해야 S3의 `recovery.zip`이 갱신됩니다.
- 실행하는 IAM 유저에 IAM / SSM / CloudWatch Logs / CodeBuild / EventBridge / EC2(EIP) 권한이 필요합니다.

**온프레 하트비트용 키 꺼내기**

```bash
terraform output -raw onprem_access_key_id
terraform output -raw onprem_secret_access_key
```

하트비트 CronJob은 아래 형식으로 1분마다 메트릭을 보내야 합니다.

```bash
aws cloudwatch put-metric-data --namespace Wegovy/DR --metric-name Heartbeat \
  --dimensions Cluster=onprem --value 1
```

---

## aws-dr

CodeBuild가 `recovery.zip`으로 받아서 실행하는 DR 환경입니다. **사람이 직접 apply 하지 않습니다.**

| 파일 | 내용 |
| --- | --- |
| [network.tf](aws-dr/network.tf) | VPC `10.50.0.0/16`, 퍼블릭 서브넷, SG (80/443 공개, 노드 간 전체 허용, 6443은 `admin_cidrs`만) |
| [compute.tf](aws-dr/compute.tf) | Ubuntu 24.04 master 1 + worker `worker_count`(기본 1), kubeadm join 토큰 생성, EIP 연결 |
| [templates/common.sh](aws-dr/templates/common.sh) | containerd 2.x, kubeadm/kubelet/kubectl 1.36, AWS CLI |
| [templates/master.sh.tftpl](aws-dr/templates/master.sh.tftpl) | kubeadm init → Flannel → local-path → MongoDB/mongo-express → S3 백업 복원 → `dr-manifests/` apply |
| [templates/worker.sh.tftpl](aws-dr/templates/worker.sh.tftpl) | master 준비될 때까지 재시도하며 join |

온프레와 맞춘 값: Kubernetes 1.36, Flannel v0.28.9, 파드 대역 `10.244.0.0/16`, MongoDB 6.0, NodePort 30017/30081.

변수(`backup_bucket`, `backup_key`, `instance_profile_name`, `eip_allocation_id`, `mongo_password_parameter`)는 CodeBuild 환경변수 `TF_VAR_*`로 aws-bootstrap이 넘겨줍니다.

**복구 진행 확인 / RTO·RPO 측정**

```bash
aws ssm start-session --target <master 인스턴스 ID>
sudo tail -f /var/log/dr-bootstrap.log
```

| 로그 | 의미 |
| --- | --- |
| `DR_BOOT_START` | user-data 시작 |
| `DR_CLUSTER_READY` | 노드 Ready |
| `DR_DB_READY` | MongoDB 기동 |
| `DR_BACKUP_LAST_MODIFIED` | 복원한 백업 시각 (**RPO** 계산용) |
| `DR_DB_RESTORED` | 복원 완료 |
| `DR_BOOT_DONE` | 전체 완료 |

---

## 테스트 / 페일백

```bash
# 1. 장애 없이 CodeBuild만 수동 실행 (DR 환경 생성)
aws codebuild start-build --project-name wegovy-dr-recovery

# 2. 알람을 강제로 ALARM 으로 바꿔서 EventBridge 연결 확인 (알람이 OK 상태일 때)
aws cloudwatch set-alarm-state --alarm-name wegovy-onprem-heartbeat \
  --state-value ALARM --state-reason "DR test"

# 3. 페일백 후 DR 환경 정리
aws codebuild start-build --project-name wegovy-dr-recovery \
  --environment-variables-override name=TF_ACTION,value=destroy,type=PLAINTEXT
```

> EventBridge는 알람이 **OK → ALARM** 으로 바뀔 때만 반응합니다. 하트비트가 한 번도 들어오지 않아 알람이 OK가 된 적이 없으면 자동 복구도 시작되지 않습니다.

---

## 주의 사항

- **state 파일에 비밀번호와 액세스 키가 평문으로 저장됩니다.** `*.tfstate`, `*.tfvars`, `*.tfplan`은 커밋하지 않습니다.
- onprem 네임스페이스는 `prevent_destroy`가 걸려 있어 `terraform destroy`로 삭제되지 않습니다.
- NFS StorageClass는 `reclaim_policy = "Retain"`이라 PVC를 지워도 데이터가 남습니다.
- Prometheus는 아직 영구 저장소가 연결되지 않아 Pod 재시작 시 메트릭이 사라집니다. 이후 `nfs-prometheus` StorageClass로 연결할 예정입니다.
- 백업이 1시간 주기라 **RPO는 최대 1시간**입니다.
- 미리 할당한 EIP는 EC2에 붙어 있지 않아도 요금이 나옵니다 (월 약 $3.6).
- CodeBuild 역할은 이 리전 안에서 `ec2:*` 권한을 가집니다.

