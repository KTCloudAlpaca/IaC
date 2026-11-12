# server-wegovy-terraform

온프레미스 Kubernetes 장애를 감지해 AWS의 DR 서버에서 서비스를 자동으로 복구하는 **Hybrid Cloud DR** 프로젝트의 Terraform 코드입니다.

## 구조

| 폴더 | 역할 | 실행 |
| --- | --- | --- |
| [onprem/](onprem/) | 온프레 Kubernetes 환경 전체. **같은 코드로 DR 서버에도 똑같이 구축** | 온프레: 사람 / DR: DR 서버의 recover.sh |
| [aws-bootstrap/](aws-bootstrap/) | EventBridge, CodeBuild, IAM, ECR, SSM 파라미터 등 사전 준비 | 사람 (처음 1회, 코드 변경 시) |
| [aws-dr/](aws-dr/) | DR 복구/페일백 스크립트 (`onprem/`과 함께 `recovery.zip`으로 S3에 올라감) | CodeBuild가 SSM으로 DR 서버에 실행을 지시 |

Terraform 명령은 **각 폴더 안에서** 실행합니다.

> **CodeBuild는 Terraform을 직접 실행하지 않습니다.** DR 서버의 쿠버네티스 API(6443)는 외부에 열려 있지 않아서, CodeBuild는 SSM Run Command로 DR 서버에 명령만 보내고 Terraform은 **DR 서버 안에서** 실행됩니다. 또한 Terraform은 클러스터 자체를 만들지 않고, 이미 설치된 쿠버네티스 위에 앱·DB·모니터링 환경을 만듭니다.

## 복구 흐름

```
온프레 하트비트 끊김 (1분 × 2회)
  → CloudWatch 알람 (OK → ALARM)
  → EventBridge → CodeBuild
  → SSM Run Command 로 DR 서버에서 recover.sh 실행 (평소엔 쿠버네티스만 설치된 상태)
      S3 recovery.zip 다운로드 → NFS 서버·앱 이미지(ECR) 준비
      → DR 서버 안에서 onprem Terraform apply (env/backup.tfvars) 로 온프레와 같은 환경 생성
      → S3 최신 백업으로 MongoDB 복원 (한 번만) → nginx 로컬 전환

(동시에) Route 53 이 온프레 헬스체크 실패를 감지해 Secondary(DR 서버)로 트래픽 전환
```

- **DR 서버:** 팀원이 띄워 둔 `EC2Backup`을 사용합니다. CodeBuild는 인스턴스 ID를 고정하지 않고, Route 53 Secondary용 EIP가 붙은 인스턴스를 매번 조회해서 찾습니다.
- **백업:** 팀 S3 버킷의 `backups/full-cluster-backup.tar.gz`를 사용합니다. 온프레 master의 crontab이 **10분마다** 같은 이름으로 덮어써서 항상 최신 백업 하나가 유지됩니다 (**RPO 최대 10분**).
- **중복 실행 방지:** CodeBuild는 `concurrent_build_limit = 1`로 동시에 하나만 돌고, 복원이 끝나면 DR 서버에 표시 파일을 남겨 recover.sh가 다시 실행돼도 DR 중에 쌓인 데이터를 덮어쓰지 않습니다.

## 검증 결과

VM을 직접 꺼서 장애를 재현하고 자동 복구부터 페일백까지 전체 시나리오를 검증했습니다.

| 지표 | 결과 |
| --- | --- |
| RTO | 평균 약 230초 (감지 2분 + 자동 복구) |
| RPO | 최대 10분 (10분 주기 백업) |

## onprem

**하나의 코드로 두 환경을 관리합니다.** 환경마다 다른 값(NFS 서버, 노드 고정, MetalLB 여부 등)만 변수로 나눴습니다.

| 환경 | workspace | 변수 | 동작 |
| --- | --- | --- | --- |
| 온프레 | `default` | 기본값 | 팀원이 만든 리소스를 `import` 로 가져와 관리 |
| DR 서버 | `backup` | [env/backup.tfvars](onprem/env/backup.tfvars) | 빈 클러스터에 전부 새로 만들어 **온프레와 같은 환경** 구축 |

| 파일 | 관리 대상 |
| --- | --- |
| [namespaces.tf](onprem/namespaces.tf) | 네임스페이스 `ai`, `app`, `db`, `monitor` (`prevent_destroy`) |
| [app.tf](onprem/app.tf) | frontend / backend Deployment·Service, `backend-secret` |
| [database.tf](onprem/database.tf) | MongoDB StatefulSet·Service, mongo-express |
| [storage.tf](onprem/storage.tf) | NFS CSI 드라이버(Helm 4.13.4), MongoDB PV/PVC |
| [prometheus.tf](onprem/prometheus.tf) | kube-prometheus-stack (15일 보관, `nfs-prometheus` 5Gi), NFS StorageClass 2개, 로그 PVC |
| [logging.tf](onprem/logging.tf) | Prometheus 로그 수집기 (fluent-bit DaemonSet) |
| [addons.tf](onprem/addons.tf) | Istio 1.31.1(demo), `main-gateway`, MetalLB v0.14.8 — 빈 클러스터에서만 설치 |

**온프레**

```bash
cd onprem
terraform init
terraform apply   # terraform.tfvars 에 mongo_root_password 필요
```

첫 `apply`는 가져오기만 합니다. Terraform 전용 값(`wait_for_*`)과 Helm 기록(revision +1)만 바뀌고 파드는 재시작되지 않습니다.

**DR 서버에 같은 환경 구축**

장애 시에는 recover.sh 가 아래와 같은 일을 DR 서버 안에서 자동으로 합니다 (state: DR 서버 `/opt/wegovy-dr/terraform`). 직접 테스트할 때만 아래처럼 수동으로 실행합니다.

```bash
# 1. EC2Backup 에서: NFS 서버(/data/*) + 앱 이미지(ECR → 온프레와 같은 이름)
sudo bash prepare-backup-node.sh      # onprem/scripts/prepare-backup-node.sh

# 2. 온프레 master 에서: DR 클러스터 접속 (SSH 터널 → ~/.kube/backup.conf)
./onprem/scripts/backup-kubeconfig.sh

# 3. 같은 Terraform 코드로 나머지 전부
cd onprem
terraform workspace new backup     # 처음 한 번 (state 분리)
terraform apply -var-file=env/backup.tfvars
```

- 쿠버네티스 자체는 EC2Backup 에 미리 설치되어 있어야 합니다 (현재 kubeadm v1.31.14 + Calico 설치됨).
- 온프레와 다른 점: 쿠버네티스 버전/CNI(온프레 1.36.3 + Flannel), 노드 1대(master 에도 파드 배치), MetalLB 없음(AWS VPC 에서 L2 미동작, nginx 가 대신함).
- Prometheus + Istio 까지 올리므로 **메모리 8GB(t3.large) 이상**이 필요합니다.
- 수동으로 만든 환경은 master 의 `backup` workspace state 에 기록됩니다. 장애 시 자동으로 만든 환경(DR 서버 state)과 섞이지 않도록, 수동 테스트 후에는 `terraform destroy` 로 정리하세요 (네임스페이스는 `prevent_destroy` 라 `terraform state rm` 후 `kubectl delete ns`).
- 클러스터를 `kubectl`로 직접 바꾸면 코드와 달라집니다. 바꿀 때는 코드도 같이 고치고 `plan`으로 확인하세요.
- **IaC 범위 밖:** 백업 크론(호스트 crontab), 하트비트 크론(호스트 crontab)

## aws-bootstrap

```bash
cd aws-bootstrap
export AWS_PROFILE=<본인 프로필>
terraform init
terraform apply   # terraform.tfvars 에 mongo_root_password (온프레와 같게) 필요
```

- `aws-dr/` 또는 `onprem/`을 수정했으면 다시 `apply` 해야 S3의 `recovery.zip`이 갱신됩니다 (내용이 바뀌면 해시가 달라져 자동으로 다시 업로드).
- `recovery.zip`에는 비밀번호가 담긴 `terraform.tfvars`, state, `.terraform/`이 포함되지 않습니다.
- 하트비트와 알람은 팀원이 만든 것을 씁니다 (`OnPrem/Kubernetes` / `Heartbeat` / `Cluster=onprem-k8s`, 알람 `EC2-trigger-alarm`, 누락 데이터는 `breaching`으로 처리). Terraform은 알람을 참조만 하며, 알람 이름이 바뀌면 `heartbeat_alarm_name` 변수도 바꿔야 합니다.
- **자동 복구는 기본으로 꺼져 있습니다** (`auto_recovery_enabled = false`). 하트비트가 꾸준히 들어오는 걸 확인한 뒤 `terraform.tfvars`에 `auto_recovery_enabled = true`를 넣고 다시 `apply` 합니다.
- `route53.tf`는 코드화를 위해 작성했지만, 실제 Failover 레코드는 담당 팀원이 콘솔로 운영 중이라 충돌하지 않도록 `enable_route53 = false`로 꺼 두었습니다.

## 앱 이미지 ECR 업로드

DR 서버는 ECR 이미지를 온프레와 같은 이름(`docker.io/library/launcher-*`)으로 저장해서 같은 `app.tf` 로 실행합니다. 앱 버전을 올릴 때마다 **이미지가 있는 노드에서** ECR로 push 하고, [onprem/app.tf](onprem/app.tf)의 이미지 태그와 aws-bootstrap의 `app_image_tag`를 같이 바꿉니다.

## DR 서버(EC2Backup) 준비

평소에는 **쿠버네티스만 설치된 상태**로 두면 됩니다. 장애 시 recover.sh 가 환경을 만들고, 페일백 시 failback-finish.sh 가 다시 지웁니다. DR 서버의 IAM 역할(팀원이 콘솔에서 생성)에 아래 정책이 필요합니다.

- `AmazonSSMManagedInstanceCore`: CodeBuild 명령 수신, MongoDB 비밀번호 조회
- `AmazonEC2ContainerRegistryReadOnly`: ECR 이미지 받기
- `AmazonS3FullAccess`(현재 붙어 있음): recovery.zip·백업 다운로드, 페일백 덤프 업로드. 필요한 버킷 경로만 허용하도록 줄이는 것이 개선점입니다.

복구 로그는 DR 서버의 `/var/log/wegovy-dr.log`에 남습니다. RTO는 하트비트가 마지막으로 들어온 시각(또는 온프레를 끈 시각)부터 `DR_RECOVER_DONE`까지로 계산하고, RPO는 `DR_BACKUP_LAST_MODIFIED`로 확인합니다. (`DR_RECOVER_START`는 스크립트 시작 시각이라 장애 시각이 아닙니다.)

## 테스트

```bash
aws codebuild start-build --project-name wegovy-dr-recovery
```

> **실제로 nginx가 DR 서버로 전환됩니다.** 테스트 후에는 아래 페일백으로 되돌려야 합니다.
> 자동 실행은 `EC2-trigger-alarm`이 **OK → ALARM**으로 바뀔 때만 일어납니다. 하트비트가 꾸준히 들어와 알람이 OK 상태여야 자동 복구가 동작합니다.

## 페일백

온프레가 살아나면 master 노드에서 실행합니다. 데이터를 덮어쓰는 작업이라 자동이 아니라 운영자가 상태를 확인한 뒤 직접 실행합니다.

```bash
AWS_PROFILE=wegovy ./onprem/scripts/failback.sh
```

| 단계 | 내용 | 코드 |
| --- | --- | --- |
| 1 | 온프레 노드 Ready + app / monitor / db 서비스 구동 확인 | [onprem/scripts/failback.sh](onprem/scripts/failback.sh) |
| 2 | 온프레 앱 0개로 내림 → 헬스체크 실패 → 트래픽은 계속 DR | 〃 |
| 3 | 온프레 현재 DB 스냅샷 → S3 `failback/onprem-before-<ID>.archive` | 〃 |
| 4 | DR 앱 중지 + DR DB 덤프 → S3 `failback/dr-<ID>.archive` (**서비스 중단 시작**) | CodeBuild → [failback-export.sh](aws-dr/scripts/failback-export.sh) |
| 5 | 온프레에 복원 → DB 연결 확인 후 30초 대기 → 온프레 앱 시작 → Route 53 이 온프레로 전환 (**서비스 재개**) | [onprem/scripts/failback.sh](onprem/scripts/failback.sh) |
| 6 | DR 서버 nginx 원복, DR 환경 destroy → **삭제 확인**(네임스페이스·state·CRD 0개, DR 서버 경유 응답 200) | CodeBuild → [failback-finish.sh](aws-dr/scripts/failback-finish.sh) |

- 온프레 앱은 **복원이 끝난 뒤에** 올립니다. 먼저 올리면 Route 53 이 장애 이전 데이터로 트래픽을 돌려보냅니다.
- 실패하면 몇 단계에서 멈췄는지와 다음 조치를 출력합니다. 문제가 있으면 `onprem-before-<ID>.archive`로 온프레 DB를 되돌릴 수 있습니다.
- CodeBuild 수동 테스트 후 원복할 때도 이 스크립트를 쓰면 됩니다.

## 알려진 한계와 개선점

| 항목 | 현재 | 개선 방향 |
| --- | --- | --- |
| state | 로컬, 잠금 없음 | S3 backend + `use_lockfile` |
| 비밀값 | state에 평문으로 남음 (`sensitive`는 출력만 가림) | write-only 인수로 state에 남기지 않기 |
| IaC 범위 | EC2, DR 서버 IAM 역할, 알람, S3 버킷, EIP, Route 53은 콘솔 구성 | `import`로 통합 |
| Istio | `local-exec`라 drift를 감지하지 못함 | `helm_release`로 전환 |
| 트래픽 전환 | Route 53 Secondary에 헬스체크가 없어 DR 앱이 뜨기 전에 트래픽이 먼저 넘어감 | Secondary 헬스체크 추가 |
| recovery.zip | 코드를 고치고 apply를 안 하면 DR이 옛 코드로 뜸 | git push 때 CI로 자동 업로드 |
