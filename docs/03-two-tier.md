# 3 — Build the application and database tiers

## Goal

Create a network boundary you can explain. Use the `infra/dev` starter, `us-east-2`, Ubuntu 24.04 x86_64 on EC2, and PostgreSQL on RDS. Select currently supported RDS PostgreSQL and AMI versions in your account and pin them in your configuration.

## Current checkpoint: implemented and planned

Milestone 3 is implemented in `network.tf`, `database.tf`, and `compute.tf`. Local inputs select Ubuntu AMI `ami-02ad619be5bc165df` (Canonical Ubuntu 24.04, x86_64), PostgreSQL `17.11`, and AZs `us-east-2a` / `us-east-2b`, verified against AWS in this account. The learner ingress is currently `142.126.208.215/32`; update it if your public IP changes.

The separate S3 dev backend is initialized at `dev/order-manager/terraform.tfstate`. The saved plan is **30 additions, 0 changes, 0 deletions**. No Milestone 3 AWS resources have been applied by the assistant.

From the project root, review and apply in PowerShell:

```powershell
$env:AWS_PROFILE = "default"
terraform '-chdir=infra/dev' show network.tfplan
terraform '-chdir=infra/dev' apply network.tfplan
```

To regenerate after any configuration/input change:

```powershell
terraform '-chdir=infra/dev' plan '-input=false' '-out=network.tfplan'
```

RDS/EC2, storage, the managed secret, logs, and public IPv4 incur charges while retained. This temporary lab explicitly uses `db_skip_final_snapshot=true`: destroying it discards demo database data and its automated backups. Set it to false and supply a unique `db_final_snapshot_identifier` before planning if you want to retain a final snapshot. Minor database upgrades are manual so the engine remains pinned.

Validation, six mocked Terraform tests, the startup script syntax check, and the existing 21 Python tests passed. Mocked tests do not verify an actual EC2 boot or RDS deployment; those are checked after apply.

## Resource checklist

- VPC `10.20.0.0/16`, DNS support and DNS hostnames enabled.
- Two public subnets: `10.20.1.0/24`, `10.20.2.0/24`, across two available AZs.
- Two database subnets: `10.20.11.0/24`, `10.20.12.0/24`, across those AZs.
- Internet gateway and default route for public subnets only. DB subnets have no internet default route.
- EC2 `t3.micro`, encrypted root disk, public IPv4, IMDSv2 required.
- Application security group: TCP 8000 from your IPv4 /32 only; no SSH. Outbound access permits package downloads, SSM, Secrets Manager, and Step Functions.
- Database security group: TCP 5432 from the application security group only.
- RDS DB subnet group, single-AZ `db.t3.micro`, 20 GiB encrypted storage, database `orders`, PostgreSQL master user `labadmin`.
- `publicly_accessible=false` and RDS-managed master password in Secrets Manager.
- Explicit deletion/snapshot policy appropriate to temporary demo data. Document your choice before teardown.
- EC2 IAM instance profile: SSM managed-node access plus the application permissions in [contracts](contracts.md).

No NAT gateway, load balancer, or Lambda VPC attachment is needed at this stage. Two DB subnets satisfy the subnet-group topology; they do not make a single-AZ DB highly available.

## Configure and inspect

The ignored dev tfvars and backend files are populated for this account, and the S3 backend block is active. For a fresh checkout, copy and fill the examples. State must stay separate from bootstrap.

```bash
terraform -chdir=infra/dev init -backend-config backend.s3.tfbackend
terraform -chdir=infra/dev fmt
terraform -chdir=infra/dev validate
terraform -chdir=infra/dev plan -out=network.tfplan
```

Expected plan: your VPC, routes, subnets, security groups, instance profile, EC2, RDS, and related resources. No changes outside this project's state.

Apply only after reviewing account, region, security groups, costs, and deletions.

```bash
terraform -chdir=infra/dev apply network.tfplan
terraform -chdir=infra/dev output
```

`release_sha` defaults to null and `lambda_hashes` to an empty map until Lambda resources exist. Milestone 5 generates real package hashes. Do not insert dummy artifact references just to plan Milestone 3.

## Host setup and post-apply verification

`compute.tf` uses the implemented `user-data.sh`, not the old example. It installs Python 3.12/venv, curl, AWS CLI 2.32.0, uv 0.13.4, and enables the SSM snap agent. CLI/uv downloads are checked against recorded SHA256 values. Ubuntu packages use signed apt repositories; SSM snap updates follow its stable channel. It creates the `orderapp` user and release directories and writes `/var/lib/order-manager/bootstrap.ready` on success. Updating this script replaces the instance so provisioning runs again.

PostgreSQL logs export to an explicit CloudWatch log group with seven-day retention. Host setup logs remain in `/var/log/cloud-init-output.log` and can be inspected through SSM. Application log shipping and Lambda/Step Functions log groups are later milestones.

The deployment helper later installs the service and app. Before that, verify SSM connectivity and use the instance's AWS role to read only its DB secret. Do not print passwords into logs. The app retrieves the password at startup and connects using TLS. Restart the service after password rotation; automatic rotation recovery is an extension.

```powershell
terraform '-chdir=infra/dev' output
aws ssm describe-instance-information --region us-east-2 --profile default
$instanceId = terraform '-chdir=infra/dev' output -raw instance_id
aws ssm start-session --region us-east-2 --profile default --target $instanceId
```

The last command needs the AWS Session Manager plugin on your computer. Alternatively, open the instance in the AWS console and choose Connect → Session Manager. Inside the session:

```bash
sudo cloud-init status --wait
test -f /var/lib/order-manager/bootstrap.ready
aws --version
uv --version
python3 --version
```

The `app_url` output is reserved for the future deployed Flask app. Port 8000 has no listener yet, so a browser connection is not a Milestone 3 health check. Keep `LAB_READY` unset: Step Functions outputs and the GitHub roles' resource deployment permissions are not implemented yet.

## Checkpoint

- EC2 appears as an online SSM managed node.
- RDS is private and its security group references the app security group.
- App security group has no `0.0.0.0/0` inbound rule and no port 22.
- Real outputs follow [contracts](contracts.md).
- You can explain why DB subnets do not need a NAT gateway.

## Hints and troubleshooting

RDS creation can take several minutes. A disconnected SSM node usually means missing instance-role permissions, a stopped agent, or no outbound route/DNS. A DB connection timeout is usually routing/security groups; an authentication error is a different problem.

## Interview prompts

What does a security-group reference permit? Does “private subnet” itself enforce database isolation? Why is this single-instance design not highly available?

## Run the offline checks

```powershell
terraform '-chdir=infra/dev' validate
terraform '-chdir=infra/dev' test
```

Tests cover private routing, two-AZ placement, Single-AZ encryption, RDS-managed passwords, restricted security groups, IMDSv2, SSM, and snapshot choices. All use a mocked provider and create no AWS resources.
