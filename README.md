# server-wegovy-terraform

온프레미스 Kubernetes 장애를 감지해 AWS의 DR 서버에서 서비스를 자동으로 복구하는 **Hybrid Cloud DR** 프로젝트의 Terraform 코드입니다.

## 구조

| 폴더 | 역할 | 실행 |
| --- | --- | --- |
| [onprem/](onprem/) | 온프레 Kubernetes 리소스 (네임스페이스, MongoDB, Prometheus) | 사람 |
| [aws-bootstrap/](aws-bootstrap/) | 알람, EventBridge, CodeBuild, IAM, ECR 등 사전 준비 | 사람 (1회) |
| [aws-dr/](aws-dr/) | DR 복구 스크립트와 앱 YAML (`recovery.zip`으로 올라감) | CodeBuild |

Terraform 명령은 **각 폴더 안에서** 실행합니다.

## 복구 흐름

```
온프레 하트비트 끊김 (3분)
  → CloudWatch Alarm (OK → ALARM)
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
- 온프레 하트비트용 키: `terraform output -raw onprem_access_key_id` / `onprem_secret_access_key`
- 하트비트 형식: `aws cloudwatch put-metric-data --namespace Wegovy/DR --metric-name Heartbeat --dimensions Cluster=onprem --value 1`

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

> **실제로 nginx가 DR 서버로 전환됩니다.** 테스트 후에는 아래 페일백 내용대로 되돌려야 합니다.
> 자동 실행은 알람이 **OK → ALARM**으로 바뀔 때만 일어납니다. 하트비트가 한 번도 안 들어왔으면 자동 복구도 안 됩니다.

## 페일백 담당자 인수인계

recover.sh가 DR 서버에서 바꾸는 것:

| 바뀌는 것 | 되돌리는 방법 |
| --- | --- |
| nginx `/etc/nginx/conf.d/alpaca-proxy.conf` (온프레 → DR 서버) | `/etc/nginx/dr-backup/alpaca-proxy.conf.onprem`으로 덮어쓰고 `nginx -t && systemctl reload nginx` |
| 복원 표시 `/var/lib/wegovy-dr/restored` | 삭제 (안 지우면 다음 장애 때 복원을 건너뜀) |
| DR 중 쌓인 데이터 (k3s `db/mongodb-0`) | `mongodump`로 꺼내 온프레에 복원 |

## 주의 사항

- DR 서버는 단일 노드(k3s)입니다. RTO와 비용을 위해 다이어그램의 master 3대 구성에서 의도적으로 단순화했습니다.
