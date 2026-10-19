# 백업 EC2(EC2Backup) 에 온프레와 같은 환경을 새로 구축할 때
#   cd onprem && terraform workspace select backup
#   terraform apply -var-file=env/backup.tfvars
# 사전 준비: 쿠버네티스 설치(완료) -> scripts/prepare-backup-node.sh (EC2Backup) -> scripts/backup-kubeconfig.sh (master)

kubeconfig_path   = "~/.kube/backup.conf" # backup-kubeconfig.sh 가 만듦 (SSH 터널)
import_existing   = false                 # 빈 클러스터 -> 전부 새로 만듦
nfs_server        = "172.31.12.230"       # EC2Backup 사설 IP (자기 자신이 NFS 서버)
app_node_selector = {}                    # 단일 노드
enable_metallb    = false                 # AWS VPC 에서는 MetalLB L2 가 동작하지 않음
