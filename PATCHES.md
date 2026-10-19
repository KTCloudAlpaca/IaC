KTCloudAlpaca/IaC 통합 패치
이 가이드는 팀의 기존 Terraform 루트(Root)를 대체하는 것이 아니라, 추가 애드온 오버레이(Add-on Overlay)로 적용되는 패치입니다. 기존의 onprem/, aws-bootstrap/, aws-dr/ 상태(State) 분리 구조를 그대로 유지하세요.

A. AWS 부트스트랩 자동화 추가
aws-bootstrap/failback-automation.tf 파일과 aws-bootstrap/failback-build/ 디렉토리 전체를 리포지토리의 기존 aws-bootstrap/ 디렉토리로 복사합니다.

이 오버레이는 현재 리포지토리의 기존 이름들(var.project, var.region, data.aws_s3_bucket.dr, aws_cloudwatch_metric_alarm.heartbeat, aws_iam_user.onprem, aws_iam_role.ec2)을 사용합니다. 이 리소스들을 중복으로 생성하지 마세요.

권한을 검토한 후에만 aws-bootstrap을 적용하세요. 이 작업으로 CodeBuild 프로젝트 1개(wegovy-dr-failback, var.project="wegovy"인 경우), 제한된 CodeBuild 역할(Role), S3 활성 환경 마커(Active-environment marker), 그리고 페일백 전용 S3 권한이 추가됩니다.

B. AWS DR 마스터에 내보내기/복구(Export/Resume) 헬퍼 설치
다음 두 파일을 기존 aws-dr/templates/ 디렉토리로 복사합니다:

aws-dr/templates/failback-export.sh

aws-dr/templates/failback-resume-aws.sh

aws-dr/compute.tf의 기존 locals 블록 바로 옆에 다음 헬퍼 파일 로컬(local) 변수들을 추가합니다:

Terraform
locals {
  # 기존 locals도 그대로 유지하세요.
  failback_export_script = file("${path.module}/templates/failback-export.sh")
  failback_resume_script = file("${path.module}/templates/failback-resume-aws.sh")
}
만약 compute.tf에 이미 locals {} 블록이 존재한다면, 동일한 이름의 두 번째 locals 블록을 만들지 말고 해당 블록에 이 두 속성을 추가하세요. aws_instance.master의 templatefile(..., { ... }) 맵(Map) 안에 다음을 추가합니다:

Terraform
failback_export_script = local.failback_export_script
failback_resume_script = local.failback_resume_script
aws-dr/templates/master.sh.tftpl 파일 내에서, 기존 ${common} 확장 구문 바로 뒤에 다음 내용을 삽입합니다:

Bash
# 제어된 페일백 헬퍼 설치. 이 스크립트는 SSM Run Command를 통해서만 호출됩니다.
install -d -m 0700 /usr/local/sbin /var/lib/dr-failback
cat > /usr/local/sbin/dr-failback-export.sh <<'FAILBACK_EXPORT_SCRIPT'
${failback_export_script}
FAILBACK_EXPORT_SCRIPT
cat > /usr/local/sbin/dr-failback-resume-aws.sh <<'FAILBACK_RESUME_SCRIPT'
${failback_resume_script}
FAILBACK_RESUME_SCRIPT
chmod 0700 /usr/local/sbin/dr-failback-export.sh /usr/local/sbin/dr-failback-resume-aws.sh

# 실패 시 차단(Fail closed): 온프레미스 준비 상태 게이트는 AWS DR이 권한을 갖고 있는 동안 통과되지 않아야 합니다.
printf 'aws-dr\n' >/tmp/failback-active-environment
aws s3 cp /tmp/failback-active-environment \
  "s3://${backup_bucket}/failback/control/active-environment" \
  --region "${region}"
해당 파일은 이미 backup_bucket과 region을 templatefile로 전달하고 있습니다. 헬퍼 스크립트 텍스트는 변수로 보간(Interpolation)되며, 스크립트 내부의 쉘 ${...} 표현식들은 Terraform에 의해 다시 파싱되지 않습니다.

aws-dr을 수정한 후, aws-bootstrap에서 terraform plan을 실행하고 재적용(terraform apply)하여 recovery.zip을 갱신하세요. 노트북에서 aws-dr Terraform을 직접 실행하지 마세요. 현재 README에 따르면 CodeBuild가 해당 상태(State)를 관리합니다. 현재 실행 중인 DR 마스터는 사용자 데이터(User-data)를 자동으로 수신하지 않으므로, 계획된 테스트에서 재생성/업데이트하거나 제어된 SSM 명령을 사용하여 기존 마스터에 헬퍼 스크립트를 직접 설치하세요.

C. Route 53은 Primary(기본)에만 준비 상태 게이트(Readiness gate) 사용
기존 aws-bootstrap/variables.tf에 다음을 추가합니다:

Terraform
variable "primary_health_check_port" {
  type        = number
  description = "온프레미스 페일백 준비 상태 게이트의 NodePort."
  default     = 30082
}

variable "primary_health_check_path" {
  type        = string
  description = "온프레미스가 활성 환경일 때만 HTTP 200을 반환하는 경로."
  default     = "/dr-ready"
}
aws-bootstrap/route53.tf에서 오직 aws_route53_health_check.primary만 수정하여 다음을 사용하도록 변경합니다:

Terraform
port          = var.primary_health_check_port
resource_path = var.primary_health_check_path
aws_route53_health_check.secondary는 기존 AWS DR 헬스 엔드포인트(일반적으로 포트 80 및 /health)로 그대로 유지합니다. 온프레미스 애드온은 NodePort 30082를 통해 /dr-ready를 노출합니다. 엣지 방화벽/라우팅이 Route 53 헬스 체커의 onprem_public_ip:30082 접근을 허용하는지 Route 53을 활성화하기 전에 반드시 확인하세요.

D. 온프레미스 복원 워커 배포
쓰기 작업(Write-capable)이 가능한 모든 Deployment의 메타데이터 및 파드 템플릿에 dr-failback-managed=true 라벨을 지정합니다. 쓰기를 수행하는 CronJob과 그 Job/Pod 템플릿에도 라벨을 지정하세요. MongoDB StatefulSet, 인그레스(Ingress), 준비 상태 게이트에는 라벨을 지정하지 마세요. 라벨이 지정된 쓰기 워크로드가 없으면 스크립트가 복원을 의도적으로 거부합니다.

app과 ai가 올바른 쓰기 워크로드 네임스페이스인지 확인하세요. 그에 맞춰 failwork_workload_namespaces를 설정합니다.

기존 aws-bootstrap 출력값에서 자격 증명을 가져옵니다:

Bash
cd aws-bootstrap
terraform output -raw onprem_access_key_id
terraform output -raw onprem_secret_access_key
onprem-failback/terraform.tfvars.example을 onprem-failback/terraform.tfvars로 복사하고, 실제 값을 입력한 뒤 Git에 포함되지 않도록 관리합니다.

state_storage_class와 work_storage_class가 존재하는지 확인하세요. 전용 NFS StorageClass를 권장하며, nfs-prometheus는 리포지토리의 현재 랩 기본값일 뿐입니다. 압축된 AWS 백업 크기에 온프레미스 롤백 덤프 및 압축 해제 오버헤드를 더한 것보다 큰 크기로 work_storage_size를 설정하세요.

실행:

Bash
cd onprem-failback
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=failback.tfplan
terraform apply failback.tfplan
이 두 번째 Terraform 루트는 페일백 Job, 제한된 RBAC, 자격 증명 Secret, 상태/작업 PVC, 그리고 준비 상태 게이트만 관리합니다. 기존 MongoDB StatefulSet은 관리하지 않습니다.

E. 엔드투엔드(End-to-end) 흐름
AWS DR이 활성 소스이고 모든 쓰기 워크로드가 라벨링되었는지 확인합니다.

CodeBuild에서 wegovy-dr-failback을 수동으로 시작합니다. 기본값으로 enable_automatic_failback=false로 설정되어 있습니다(의도된 설계).

CodeBuild가 DR 마스터로 SSM Run Command를 전송합니다. 내보내기(Export) 스크립트는 현재 레플리카/CronJob 상태를 저장하고, 라벨링된 Deployment를 0으로 스케일링하며, 라벨링된 CronJob을 일시 중지하고, 활성 상태의 라벨링된 Job이 있으면 거부합니다. 파드들이 중지될 때까지 대기한 뒤 mongodump를 실행하고, 비어 있지 않은 아카이브인지 검증한 뒤 failback/runs/<run-id>/backup.tar.gz 및 SHA-256을 업로드하고, 마지막에 failback/current/READY를 게시합니다.

온프레미스 CronJob이 1분마다 S3를 확인합니다. 새로운 실행(Run)이 감지되면 라벨링된 쓰기 워크로드를 일시 중지하고, 현재 온프레미스 DB를 롤백 복사본으로 S3에 덤프한 후, AWS 아카이브를 검증/다운로드하여 실행 중인 MongoDB 서비스에 대해 mongorestore를 수행합니다(/data/db에 파일을 직접 추출하는 방식이 아님).

MongoDB 핑(Ping) 체크를 실행하고, 온프레미스 워크로드를 기록된 레플리카/일시 중지 상태로 복원하며, 사용 가능한 Deployment들을 기다린 후 active-environment=onprem 및 failback/status/<run-id>/SUCCESS를 기록합니다.

준비 상태 게이트가 active-environment=onprem을 감지하고 /dr-ready에서 HTTP 200을 반환하기 시작합니다. 그 후 Route 53이 Primary 레코드를 선호(Prefer)할 수 있게 됩니다.

AWS DR 워크로드는 성공 후에도 일시 중지된 상태로 유지됩니다. 트래픽과 데이터 상태를 확인한 후에만 AWS DR 환경을 삭제하세요. 복원 Job의 일부로서 자동으로 파괴(Destroy)되도록 설정하지 마세요.

F. 장애 처리
이 워크플로우는 의도적으로 실패 시 차단(Fail-closed) 방식으로 설계되었습니다. 복원이 성공을 보고하지 않으면, 활성 환경 마커는 aws-dr 상태로 유지되며 최종 덤프가 게시된 후에도 AWS 쓰기 작업은 일시 중지된 상태로 남습니다. 온프레미스 측에서 쓰기 작업이 부분적으로만 중지되었거나 복원이 부분적으로 적용되었을 수 있으므로 자동 재개(Automatic resume)를 피해야 합니다.

로그/상태를 확인하고 온프레미스 쓰기 워크로드가 펜싱(Fencing)되었음을 검증한 후, SSM을 통해 AWS 재개 스크립트를 명시적으로 실행할 수 있습니다:

Bash
aws ssm send-command \
  --targets "Key=tag:Name,Values=wegovy-dr-master" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo /usr/local/sbin/dr-failback-resume-aws.sh <RUN_ID>"]' \
  --comment "Operator-approved recovery after failed failback"
<RUN_ID>를 실패한 실행 ID로 교체하세요. 활성 온프레미스 쓰기 작업이 없는지 확인한 후에만 이 작업을 수행하세요. 그렇지 않으면 스플릿 브레인(Split-brain)이 발생할 수 있습니다.

S3 롤백 덤프는 failback/rollback/<run-id>/onprem-before.archive 경로에 SHA-256 파일과 함께 저장됩니다. 이는 파일시스템 스냅샷이 아니라 논리적 MongoDB 덤프입니다.

mongorestore --drop은 복원하기 전에 덤프에 포함된 컬렉션을 삭제(Drop)하지만, 덤프에 없는 컬렉션은 삭제하지 않습니다. 정확한 데이터베이스 미러링이 필요한 경우, 프로덕션 환경에 배포하기 전에 명시적인 인벤토리/차이(Diff) 처리 로직을 추가하세요.

Route 53 DNS 캐싱으로 인해 헬프 체크가 변경된 후에도 서비스 트래픽이 즉시 이동하지 않습니다. TTL, 기존 연결, 애플리케이션 쓰기 동작을 테스트하세요.

G. 프로덕션 배포 전 검증
폐기 가능한(Disposable) 환경에서 먼저 테스트하세요.

프로젝트에서 사용 가능한 mongo:6.0 이미지에 aws-dr/templates/master.sh.tftpl에서 가정하는 mongodump, mongorestore, mongosh가 포함되어 있는지 확인하세요. 그렇지 않은 경우 고정된(Pinned) MongoDB Database Tools 이미지를 사용하고 스크립트를 업데이트하세요.

AWS 마스터가 SSM 관리형 인스턴스인지, 그리고 CodeBuild의 역할(Role)이 태그된 마스터에만 Run Command를 전송하도록 허용되어 있는지 확인하세요.

온프레미스 IAM 키가 필수 페일백 접두사(Prefix) S3 권한만 가지고 있는지 확인하세요. Kubernetes Secret과 Terraform 상태에는 자격 증명이 포함되어 있으므로 상태를 암호화/보호하고 키를 로테이션하세요.

모든 변경 경로(Mutation paths)에 라벨이 지정되어 있는지 확인하세요: Deployment, CronJob, 그리고 기타 워커/컨슈머 워크로드. 활성화된 라벨링된 Job이 존재하면 내보내기/복원이 중지됩니다.

Route 53 기본 헬스 체크 포트 30082는 Route 53 체커에서 접근할 수 있어야 합니다. 네트워크 외부에서 게이트 경로가 정상 작동하기 전에는 enable_route53=true를 활성화하지 마세요.

전체 복구 드릴(Drill)을 완료한 후에만 enable_automatic_failback=true로 설정하세요. 단순한 하트비트 복구만으로는 안전한 페일백이 수행될 수 있다는 증거가 되지 않습니다.
