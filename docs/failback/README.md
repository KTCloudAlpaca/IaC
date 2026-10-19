# Kubernetes DR Failback Automation (Terraform add-on)

이 패키지는 `KTCloudAlpaca/IaC`의 기존 구조에 추가하는 **참고 구현**입니다. 기존 `onprem/`, `aws-bootstrap/`, `aws-dr/`의 Terraform state를 합치지 않습니다.

- AWS `CodeBuild + SSM Run Command`: AWS DR의 쓰기 워크로드를 멈추고 MongoDB 최종 논리 백업을 S3에 게시
- On-premises Kubernetes `CronJob`: 새 백업 감지 → 현재 온프레미스 DB 롤백용 백업 → 체크섬 검증 → `mongorestore` → DB 확인 → 앱 워크로드 재개
- S3 `failback/control/active-environment`: `aws-dr`/`onprem` 현재 데이터 원본을 기록
- On-prem `NodePort 30082 /dr-ready`: S3 marker가 `onprem`일 때만 HTTP 200을 반환해 Route 53 Primary health check를 제어
- 선택적 EventBridge 규칙: 하트비트 알람이 `ALARM -> OK`로 바뀌면 CodeBuild 시작. 기본값은 비활성화.

## 파일

- `aws-bootstrap/failback-automation.tf`: 기존 `aws-bootstrap/`에 추가할 AWS 리소스/IAM
- `aws-bootstrap/failback-build/buildspec.yml`: CodeBuild가 SSM 명령을 보내고 복구 결과를 기다리는 빌드 단계
- `aws-dr/templates/failback-export.sh`: AWS MongoDB 최종 백업과 writer pause
- `aws-dr/templates/failback-resume-aws.sh`: 실패 시 운영자 승인으로 AWS writer를 재개하는 도구
- `onprem-failback/`: 온프레미스 restore CronJob, 최소 RBAC, PVC, readiness gate를 관리하는 독립 Terraform root
- `PATCHES.md`: 기존 저장소에 적용해야 할 코드 삽입과 실행 절차

## 중요: 적용 순서

1. 이 패키지는 팀 저장소에 자동 commit/push하지 않습니다. 먼저 복사한 브랜치에서 `PATCHES.md`를 따라 기존 코드에 통합하세요.
2. AWS와 On-Prem workload의 쓰기 작업에 `dr-failback-managed=true` label을 붙여야 합니다. Deployment 객체 metadata와 Pod template, CronJob과 Job/Pod template에 label을 빠뜨리지 마세요. MongoDB StatefulSet 자체에는 붙이지 않습니다.
3. `aws-bootstrap/failback-automation.tf`를 추가하고 `terraform fmt`, `validate`, `plan`을 검토한 뒤 적용합니다.
4. `aws-dr/compute.tf`와 `master.sh.tftpl`에 helper 설치 부분을 통합합니다. `aws-bootstrap`의 `recovery.zip`이 새 코드로 갱신되도록 `aws-bootstrap`을 재적용합니다. 이미 실행 중인 Master의 user-data는 자동으로 다시 실행되지 않으므로, 테스트 환경을 재생성하거나 helper를 SSM으로 안전하게 배포하세요.
5. `onprem-failback/terraform.tfvars.example`을 `terraform.tfvars`로 복사해 실제 자격 증명을 넣고 `onprem-failback/` root에서 `terraform init`, `fmt`, `validate`, `plan`을 수행합니다. 실제 `terraform.tfvars`와 `.tfstate`는 Git에 커밋하지 마세요.
6. Route 53을 사용하는 경우 기존 `route53.tf`에서 Primary health check만 `30082 /dr-ready`로 변경합니다. 온프레미스 엣지 방화벽/NAT가 Route 53 health check 요청을 NodePort 30082까지 전달해야 합니다.
7. 소규모 테스트 DB에서 먼저 전체 failback drill을 수행하세요. 성공하기 전엔 운영 도메인에 연결하지 마세요.

## 사용법

수동/운영 승인 방식(기본):

```bash
aws codebuild start-build --project-name wegovy-dr-failback
```

`var.project`를 `wegovy`가 아닌 값으로 바꾸었다면 CodeBuild 프로젝트 이름과 `failback_master_tag_value`를 실제 `aws-dr/compute.tf`의 Master `Name` 태그에 맞추세요.

자동 trigger는 `aws-bootstrap/terraform.tfvars`에 다음을 넣고 충분한 모의 훈련을 한 뒤에만 켭니다.

```hcl
enable_automatic_failback = true
```

하트비트 복구만으로는 애플리케이션, NFS, DB, 쓰기 작업이 모두 안전하게 복구되었다는 보장이 없습니다. 따라서 기본값은 `false`입니다.

## 안전 동작과 복구 정책

- AWS에서 마지막 백업을 만들기 전에 label된 writer가 0개이거나 active Job이 있으면 AWS 스크립트는 실패합니다.
- 백업을 게시하기 전 AWS 스크립트가 실패하면 저장한 replicas/CronJob state로 최대한 원상 복귀합니다.
- 백업 `READY` marker 게시 후에는 AWS writer를 계속 중지합니다. On-Prem의 성공 보고가 오기 전에는 자동 재개하지 않습니다.
- On-Prem은 덮어쓰기 전에 `failback/rollback/<run-id>/onprem-before.archive`를 S3에 저장합니다.
- On-Prem `mongorestore`나 workload 재개 검증이 실패하면 `FAILED` 상태를 게시하고 active-environment를 `aws-dr`로 유지합니다. 자동으로 양쪽 writer를 열지 않습니다.
- AWS writer 재개 helper는 운영자가 실패 상태와 온프레미스 fencing을 확인한 뒤에만 사용합니다.
- 데이터 복원 성공 후 AWS DR Terraform을 자동 `destroy`하지 않습니다. 트래픽, DB, 로그, RPO/RTO 확인 후 별도 승인으로 정리하세요.

## MongoDB 관련 전제

- 두 쪽에서 현재 MongoDB 6.0과 logical archive(`mongodump --archive`)를 사용한다고 가정합니다.
- `mongodump`, `mongorestore`, `mongosh`가 `mongo:6.0` 컨테이너 이미지에 실제로 존재하는지 먼저 확인하세요. 현재 팀의 DR template가 해당 명령을 MongoDB Pod 내부에서 호출하는 기존 동작을 기준으로 삼았습니다. 누락된 경우 공식 MongoDB Database Tools를 포함한 고정 버전 이미지를 사용하세요.
- `--drop`은 백업에 포함된 컬렉션을 drop한 뒤 복원하지만, 백업에 없는 컬렉션은 제거하지 않습니다. 복원 후 컬렉션 inventory/업무 검증을 추가하세요.
- 스크립트는 `admin.*`, `config.*`를 제외합니다. 별도 MongoDB 사용자/권한이 있다면 페일백 후에도 검증해야 합니다.
- 이 구현은 단일 MongoDB 논리 백업을 사용합니다. 쓰기가 계속되는 상태의 zero-downtime replication이나 replica-set failover를 대체하지 않습니다.

## 스토리지와 보안

- `work_storage_size`는 압축 AWS 백업, 해제된 archive, 온프레미스 롤백 archive를 감당해야 합니다. 현재 예제의 30Gi는 예시일 뿐 데이터 크기에 따라 늘리세요.
- `nfs-prometheus`는 기존 저장소의 실습 기본값일 뿐, DB 백업 staging 용도의 운영용 StorageClass로 권장하는 이름은 아닙니다. 별도 NFS share/StorageClass를 만드는 것이 좋습니다.
- 현재 on-prem Terraform secret과 Terraform state에 AWS 액세스 키/DB 비밀번호가 기록될 수 있습니다. S3 state 암호화·접근 제한을 적용하고, 운영 환경에서는 장기 IAM user 키 대신 Relay presigned URL 또는 수명이 짧은 자격 증명을 우선 검토하세요.
- AWS CLI, kubectl, nginx 이미지는 예시 태그를 사용합니다. 운영에서는 버전을 고정하고 가능한 경우 image digest를 pin하세요.
- NodePort 30082가 인터넷에 직접 열리지 않도록 가능한 범위에서 방화벽 소스를 제한하고, Route 53 Health Check의 공식 IP 범위 변경을 운영 정책에 반영하세요.

## 코드 검증 상태

- `aws-dr/templates/*.sh`는 `bash -n`으로, `onprem-failback/scripts/*.sh`는 `sh -n`으로 shell 구문 검사를 통과했습니다.
- 작업 환경에 Terraform CLI가 설치되어 있지 않아 Terraform의 `fmt`, `validate`, `plan`은 실행하지 못했습니다. 따라서 이 패키지는 **검토용 통합 초안**이며, 실제 적용 전 각 Terraform root에서 아래 명령을 반드시 실행해야 합니다.

```bash
terraform fmt -recursive
terraform init
terraform validate
terraform plan
```

## 운영 전 필수 검증

- 모든 writer Deployment/CronJob이 label selector에 포함되는지 확인
- AWS Master가 SSM Managed Instance로 Online인지 확인
- CodeBuild IAM 역할이 오직 예상 Master에 SSM Run Command를 전송하는지 확인
- on-prem IAM 권한이 `failback/` prefix 이외의 데이터에 불필요하게 접근하지 않는지 확인
- NFS RWX StorageClass와 충분한 용량 확인
- DNS/NodePort health check가 외부에서 정상 동작하는지 확인
- DB 데이터 일치, API/업무 검증, 실제 RTO/RPO 측정
- 실패/중단 시 양쪽에서 동시에 쓰기가 열리지 않는지 확인

## 참고 오픈소스

- **Kubespray**: Terraform이 EC2와 네트워크를 만든 뒤 기존 서버에 Kubernetes를 설치하는 모델과 잘 맞습니다. 이미 `aws-dr`가 `kubeadm`으로 클러스터를 직접 설치하므로, Kubespray로 바꾸려면 해당 user-data/kubeadm 구현과 중복되지 않도록 배포 주체 하나를 선택하세요.
- **kOps**: AWS 중심으로 Kubernetes 클러스터의 인프라와 라이프사이클을 관리할 때 적합합니다. 같은 AWS 클러스터의 VPC/EC2/Control Plane을 Terraform과 kOps 양쪽에서 동시에 소유하지 마세요.
- **Velero**: Kubernetes 객체와 지원되는 볼륨 데이터 백업/복구에 유용하지만 MongoDB 논리 일관성 백업을 대체하지는 않습니다. MongoDB 데이터는 현재의 `mongodump/mongorestore`, replica set/복제, 또는 검증된 DB 백업 전략과 조합하세요.

공식 자료:
- Kubespray: https://github.com/kubernetes-sigs/kubespray
- kOps: https://kops.sigs.k8s.io/
- MongoDB mongorestore: https://www.mongodb.com/docs/database-tools/mongorestore/
- AWS SSM Run Command: https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html
- Velero: https://velero.io/docs/
