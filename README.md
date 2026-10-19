# server-wegovy-terraform

온프레미스 Kubernetes 장애를 감지해 AWS의 DR 서버에서 서비스를 자동으로 복구하는 **Hybrid Cloud DR** 프로젝트의 Terraform 코드입니다.

## 구조

| 폴더 | 역할 | 실행 |
| --- | --- | --- |
| [onprem/](onprem/) | 온프레 Kubernetes 리소스 (네임스페이스, MongoDB, Prometheus) | 사람 |
| [aws-bootstrap/](aws-bootstrap/) | EventBridge, CodeBuild, IAM, ECR 등 사전 준비 | 사람 (1회) |
| [aws-dr/](aws-dr/) | DR 복구/페일백 스크립트와 앱 YAML (`recovery.zip`으로 올라감) | CodeBuild |

Terraform 명령은 **각 폴더 안에서** 실행합니다.

## 복구 흐름

```
온프레 하트비트 끊김 (5분)
  → 팀원 알람 EC2-trigger-alarm (OK → ALARM)
  → EventBridge → CodeBuild
  → SSM Run Command 로 DR 서버(EC2Backup)에서 recover.sh 실행
      k3s 기동 → MongoDB 배포 → S3 최신 백업 복원 → 앱 배포(ECR 이미지) → nginx 로컬 전환
  → Route 53 이 Secondary(43.200.208.156)로 트래픽 전환
```

- **DR 서버:** 팀원이 띄워 둔 `EC2Backup`을 사용합니다. CodeBuild는 `43.200.208.156`이 붙어 있는 인스턴스를 찾아서 실행합니다.
- **백업:** 팀 버킷 `k8s-hybrid-dr-backup-2026-...`의 `backups/full-cluster-backup.tar.gz`를 사용합니다 (매시간 갱신, **RPO 최대 1시간**).

## onprem

```bash
cd onprem
terraform init
terraform apply   # terraform.tfvars 에 mongo_root_password 필요
```

- 팀원이 만든 리소스를 `import` 블록으로 가져와 관리합니다. MongoDB용 NFS PVC는 관리 대상이 아니며 미리 있어야 합니다.
- 클러스터에 NFS CSI 드라이버(`nfs.csi.k8s.io`)가 필요합니다. NFS StorageClass는 `Retain`이라 PVC를 지워도 데이터가 남습니다.
- 네임스페이스는 `prevent_destroy`라 `destroy`로 지워지지 않습니다.
- Prometheus는 아직 영구 저장소가 없습니다. 이후 `nfs-prometheus` StorageClass로 연결할 예정입니다.

## aws-bootstrap

```bash
cd aws-bootstrap
export AWS_PROFILE=<본인 프로필>
terraform init
terraform apply   # terraform.tfvars 에 mongo_root_password (온프레와 같게) 필요
```

- 계정 `995342110514`가 아니면 실행이 막힙니다.
- `aws-dr/`을 수정했으면 다시 `apply` 해야 S3의 `recovery.zip`과 `dr-manifests/`가 갱신됩니다.
- 하트비트와 알람은 팀원이 만든 것을 씁니다 (`OnPrem/Kubernetes` / `Heartbeat` / `Cluster=onprem-k8s`, 알람 `EC2-trigger-alarm`). Terraform은 알람을 참조만 하며, 알람 이름이 바뀌면 `heartbeat_alarm_name` 변수도 바꿔야 합니다.
- **자동 복구는 기본으로 꺼져 있습니다** (`auto_recovery_enabled = false`). 하트비트가 꾸준히 들어오는 걸 확인한 뒤 `terraform.tfvars`에 `auto_recovery_enabled = true`를 넣고 다시 `apply` 합니다.

## 앱 이미지 ECR 업로드

앱 버전을 올릴 때마다 **이미지가 있는 노드에서** ECR로 push 하고, [aws-dr/manifests/app.yaml](aws-dr/manifests/app.yaml)의 이미지 태그를 바꾼 뒤 aws-bootstrap을 다시 `apply` 합니다.

```bash
REGISTRY=995342110514.dkr.ecr.ap-northeast-2.amazonaws.com
TOKEN=$(aws ecr get-login-password --region ap-northeast-2)
sudo ctr -n k8s.io images tag docker.io/library/launcher-frontend:v1 $REGISTRY/launcher-frontend:v1
sudo ctr -n k8s.io images push --user "AWS:$TOKEN" $REGISTRY/launcher-frontend:v1
# launcher-backend 도 같은 방식
```

## DR 서버(EC2Backup) 준비

IAM 역할 `EC2-S3-DR-Relay-Role`에 아래 정책이 필요합니다.

- `AmazonSSMManagedInstanceCore`: CodeBuild 명령 수신, MongoDB 비밀번호 조회
- `AmazonEC2ContainerRegistryReadOnly`: ECR 이미지 받기

복구 로그는 DR 서버의 `/var/log/wegovy-dr.log`에 남습니다. `DR_*` 줄의 시각으로 RTO를, `DR_BACKUP_LAST_MODIFIED`로 RPO를 계산합니다.

## 테스트

```bash
aws codebuild start-build --project-name wegovy-dr-recovery
```

> **실제로 nginx가 DR 서버로 전환됩니다.** 테스트 후에는 아래 페일백으로 되돌려야 합니다.
> 자동 실행은 `EC2-trigger-alarm`이 **OK → ALARM**으로 바뀔 때만 일어납니다. 하트비트가 꾸준히 들어와 알람이 OK 상태여야 자동 복구가 동작합니다.

## 페일백

온프레가 살아나면 master 노드에서 실행합니다.

```bash
AWS_PROFILE=wegovy ./onprem/scripts/failback.sh
```

| 단계 | 내용 | 코드 |
| --- | --- | --- |
| 1 | 온프레 클러스터 / MongoDB 확인 | [onprem/scripts/failback.sh](onprem/scripts/failback.sh) |
| 2 | 온프레 앱 0개로 내림 → 헬스체크 실패 → 트래픽은 계속 DR | 〃 |
| 3 | 온프레 현재 DB 스냅샷 → S3 `failback/onprem-before-<ID>.archive` | 〃 |
| 4 | DR 앱 중지 + DR DB 덤프 → S3 `failback/dr-<ID>.archive` (**서비스 중단 시작**) | CodeBuild → [failback-export.sh](aws-dr/scripts/failback-export.sh) |
| 5 | 온프레에 복원 → 온프레 앱 시작 → Route 53 이 온프레로 전환 (**서비스 재개**) | [onprem/scripts/failback.sh](onprem/scripts/failback.sh) |
| 6 | DR 서버 nginx 원복, 복원 표시 삭제, DR 앱/DB 삭제 (k3s 는 유지) | CodeBuild → [failback-finish.sh](aws-dr/scripts/failback-finish.sh) |

- 온프레 앱은 **복원이 끝난 뒤에** 올립니다. 먼저 올리면 Route 53 이 장애 이전 데이터로 트래픽을 돌려보냅니다.
- 실패하면 몇 단계에서 멈췄는지와 다음 조치를 출력합니다. 문제가 있으면 `onprem-before-<ID>.archive`로 온프레 DB를 되돌릴 수 있습니다.
- CodeBuild 수동 테스트 후 원복할 때도 이 스크립트를 쓰면 됩니다.
