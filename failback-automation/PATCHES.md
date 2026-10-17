# Integration patches for KTCloudAlpaca/IaC

This is an **add-on overlay**, not a replacement for your team's existing Terraform roots. Keep the existing `onprem/`, `aws-bootstrap/`, and `aws-dr/` state separation.

## A. Add the AWS bootstrap automation

1. Copy `aws-bootstrap/failback-automation.tf` and the whole `aws-bootstrap/failback-build/` directory into the repository's existing `aws-bootstrap/` directory.
2. This overlay relies on existing names from the current repository: `var.project`, `var.region`, `data.aws_s3_bucket.dr`, `aws_cloudwatch_metric_alarm.heartbeat`, `aws_iam_user.onprem`, and `aws_iam_role.ec2`. Do not create duplicates of those existing resources.
3. Apply `aws-bootstrap` only after reviewing the permissions. It adds one CodeBuild project named `wegovy-dr-failback` (when `var.project="wegovy"`), a limited CodeBuild role, an S3 active-environment marker, and failback-only S3 permissions.

## B. Install the export/resume helpers on the AWS DR master

Copy these two files into the existing `aws-dr/templates/` directory:

- `aws-dr/templates/failback-export.sh`
- `aws-dr/templates/failback-resume-aws.sh`

In `aws-dr/compute.tf`, add the helper file locals next to the existing `locals` block:

```hcl
locals {
  # Keep the existing locals too.
  failback_export_script = file("${path.module}/templates/failback-export.sh")
  failback_resume_script = file("${path.module}/templates/failback-resume-aws.sh")
}
```

If `compute.tf` already has a `locals {}` block, add these two attributes to it; do not create a second `locals` block with the same name. In the `templatefile(..., { ... })` map for `aws_instance.master`, add:

```hcl
failback_export_script = local.failback_export_script
failback_resume_script = local.failback_resume_script
```

In `aws-dr/templates/master.sh.tftpl`, immediately after the existing `${common}` expansion, insert:

```bash
# Install controlled failback helpers. These are only invoked by SSM Run Command.
install -d -m 0700 /usr/local/sbin /var/lib/dr-failback
cat > /usr/local/sbin/dr-failback-export.sh <<'FAILBACK_EXPORT_SCRIPT'
${failback_export_script}
FAILBACK_EXPORT_SCRIPT
cat > /usr/local/sbin/dr-failback-resume-aws.sh <<'FAILBACK_RESUME_SCRIPT'
${failback_resume_script}
FAILBACK_RESUME_SCRIPT
chmod 0700 /usr/local/sbin/dr-failback-export.sh /usr/local/sbin/dr-failback-resume-aws.sh

# Fail closed: the on-prem readiness gate should not pass while AWS DR is authoritative.
printf 'aws-dr\n' >/tmp/failback-active-environment
aws s3 cp /tmp/failback-active-environment \
  "s3://${backup_bucket}/failback/control/active-environment" \
  --region "${region}"
```

The file already passes `backup_bucket` and `region` into `templatefile`. The helper script text is interpolated as a variable; its own shell `${...}` expressions are not re-parsed by Terraform.

After modifying `aws-dr`, run `terraform plan` in `aws-bootstrap` and re-apply it so `recovery.zip` is refreshed. **Do not run `aws-dr` Terraform directly from a laptop; current README says CodeBuild owns that state.** The current running DR Master won't receive modified user-data automatically; recreate/update it in a planned test or install the helper scripts on the existing master using a controlled SSM command.

## C. Route 53 must use the readiness gate for the Primary only

In existing `aws-bootstrap/variables.tf`, add:

```hcl
variable "primary_health_check_port" {
  type        = number
  description = "NodePort of the on-prem failback readiness gate."
  default     = 30082
}

variable "primary_health_check_path" {
  type        = string
  description = "Path that returns HTTP 200 only when on-prem is the active environment."
  default     = "/dr-ready"
}
```

In `aws-bootstrap/route53.tf`, change **only** `aws_route53_health_check.primary` to use:

```hcl
port          = var.primary_health_check_port
resource_path = var.primary_health_check_path
```

Keep `aws_route53_health_check.secondary` on the existing AWS DR health endpoint (normally port 80 and `/health`). The on-prem add-on exposes `/dr-ready` through NodePort 30082. Your edge firewall/routing must permit Route 53 health checkers to reach `onprem_public_ip:30082`; verify this before enabling Route 53.

## D. Deploy the on-prem restore worker

1. Label **every write-capable** Deployment's metadata and pod template with `dr-failback-managed=true`. Label write-producing CronJobs and their Job/Pod templates as well. Do **not** label the MongoDB StatefulSet, ingress, or the readiness gate. The scripts intentionally refuse the restore if no labeled writers are found.
2. Check that `app` and `ai` are the correct write-workload namespaces. Set `failback_workload_namespaces` accordingly.
3. Get credentials from the existing `aws-bootstrap` outputs:

   ```bash
   cd aws-bootstrap
   terraform output -raw onprem_access_key_id
   terraform output -raw onprem_secret_access_key
   ```

4. Copy `onprem-failback/terraform.tfvars.example` to `onprem-failback/terraform.tfvars`, insert the actual values, and keep it out of Git.
5. Confirm `state_storage_class` and `work_storage_class` exist. A dedicated NFS StorageClass is preferred; `nfs-prometheus` is only the repo's current lab default. Set `work_storage_size` larger than the compressed AWS backup plus the on-prem rollback dump and extraction overhead.
6. Run:

   ```bash
   cd onprem-failback
   terraform init
   terraform fmt -recursive
   terraform validate
   terraform plan -out=failback.tfplan
   terraform apply failback.tfplan
   ```

This second Terraform root manages only the failback Job, limited RBAC, credentials Secret, state/work PVCs, and readiness gate. It does not manage the existing MongoDB StatefulSet.

## E. End-to-end flow

1. Check that AWS DR is the active source and all writer workloads are labeled.
2. Start `wegovy-dr-failback` manually in CodeBuild. By default, `enable_automatic_failback=false`, intentionally.
3. CodeBuild sends SSM Run Command to the DR master. The export script saves current replicas/CronJob states, scales labeled Deployments to zero, suspends labeled CronJobs, refuses active labeled Jobs, waits for pods to stop, runs `mongodump`, verifies a non-empty archive, uploads `failback/runs/<run-id>/backup.tar.gz` and its SHA-256, then publishes `failback/current/READY` **last**.
4. The on-prem CronJob checks S3 every minute. For a new run, it pauses labeled writers, dumps the current on-prem DB to S3 as a rollback copy, verifies/downloads the AWS archive, and runs `mongorestore` against the running MongoDB service (not by extracting files into `/data/db`).
5. It runs a MongoDB ping check, resumes on-prem workloads to their recorded replica/suspend state, waits for available Deployments, then writes `active-environment=onprem` and `failback/status/<run-id>/SUCCESS`.
6. The readiness gate sees `active-environment=onprem` and starts returning HTTP 200 at `/dr-ready`; Route 53 can then prefer its Primary record.
7. AWS DR workloads stay paused after success. Delete the AWS DR environment only after you confirm traffic and data health; do not destroy automatically as part of the restore Job.

## F. Failure handling

- The workflow is intentionally **fail-closed**. If restore does not report success, the active-environment marker remains `aws-dr` and AWS writers remain paused after a published final dump. Avoid automatic resume because the on-prem side may have partially paused writers or partially applied a restore.
- After checking logs/state and verifying that on-prem write workloads are fenced, you may explicitly run the AWS resume script via SSM:

  ```bash
  aws ssm send-command \
    --targets "Key=tag:Name,Values=wegovy-dr-master" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["sudo /usr/local/sbin/dr-failback-resume-aws.sh <RUN_ID>"]' \
    --comment "Operator-approved recovery after failed failback"
  ```

  Replace `<RUN_ID>` with the failed run ID. Only do this after verifying there is no active on-prem writer; otherwise split-brain is possible.
- The S3 rollback dump is in `failback/rollback/<run-id>/onprem-before.archive` with a SHA-256 file. It is a logical MongoDB dump, not a filesystem snapshot.
- `mongorestore --drop` drops collections included in the dump before restoring them, but doesn't delete collections absent from the dump. If exact database mirroring is required, add explicit inventory/diff handling before production use.
- Route 53 DNS caching means service traffic does not move instantly even after health checks change. Test TTL, existing connections, and application write behavior.

## G. Validation before production

- Test on a disposable environment first.
- Confirm the `mongo:6.0` image available in the project includes `mongodump`, `mongorestore`, and `mongosh` as assumed by the current `aws-dr/templates/master.sh.tftpl`. If not, use a pinned MongoDB Database Tools image and update the scripts.
- Verify the AWS master is an SSM managed instance and CodeBuild's role is allowed to send Run Command only to the tagged master.
- Verify the on-prem IAM key has only the required failback-prefix S3 permissions. The Kubernetes Secret and Terraform state contain credentials; encrypt/protect state and rotate the key.
- Ensure all mutation paths are labeled: Deployments, CronJobs, and any worker/consumer workloads. Active labeled Jobs cause the export/restore to stop.
- Route 53 primary health check port 30082 must be reachable from Route 53 checkers. Do not enable `enable_route53=true` until the gate path works from outside your network.
- Set `enable_automatic_failback=true` only after a full recovery drill. Heartbeat recovery alone is not proof that a safe failback should occur.
