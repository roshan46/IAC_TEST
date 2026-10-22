# 5 — Publish the repository and deploy through GitHub

## Goal

Publish this directory to `roshan46/IAC_TEST`, update the existing bootstrap roles with their Milestone 5 permissions, then deploy a reviewed commit. Pull requests run checks without AWS credentials.

## 1. Update the bootstrap roles

Milestone 5 adds `infra/bootstrap/deployment-permissions.tf`. The plan role can read application metadata. The apply role can change the named lab resources and send `AWS-RunShellScript` to an EC2 instance tagged `Project=order-manager`. Neither role can read the bootstrap state key, and neither receives `AdministratorAccess`.

After your local AWS credentials are available, review and apply this small bootstrap change first:

```bash
terraform -chdir=infra/bootstrap init -input=false -reconfigure \
  -backend-config=backend.s3.tfbackend
terraform -chdir=infra/bootstrap plan -input=false -out=milestone5-bootstrap.tfplan
terraform -chdir=infra/bootstrap apply milestone5-bootstrap.tfplan
```

Expected result: two `application-plan`/`application-apply` inline role policies are created or updated. No application resource should be changed by this bootstrap apply.

## Create your repository

The repository already exists and is empty. Run from `order-manager-lab/`, not its parent. Review ignored files before committing.

```bash
git init -b main
git add .
git status
git commit -m "Add guided order manager Terraform lab"
git remote add origin https://github.com/roshan46/IAC_TEST.git
git push -u origin main
```

A public source repository is optional. Do not commit actual tfvars, backend files, credentials, state, plans, or receipts. The app has no authentication yet; a public repository does not imply a public AWS app.

## Understand the three workflows

| Workflow | Trigger | AWS access |
| --- | --- | --- |
| Checks | Pull requests and pushes to main | None; tests, formatting, backend-free validation |
| Plan lab changes | Manual, main only | Plan role via OIDC |
| Apply reviewed plan | Separate manual action, main only | Apply role via OIDC |

Set repository variables after completing the infrastructure exercises:

| Variable | Value for this lab |
| --- | --- |
| STATE_BUCKET | `order-manager-848005667541-us-east-2-state` |
| ARTIFACT_BUCKET | `order-manager-848005667541-us-east-2-artifacts` |
| PLAN_ROLE_ARN | `arn:aws:iam::848005667541:role/order-manager/bootstrap/order-manager-github-plan` |
| APPLY_ROLE_ARN | `arn:aws:iam::848005667541:role/order-manager/bootstrap/order-manager-github-apply` |
| LEARNER_CIDR | `142.126.208.215/32` (replace when your public IP changes) |
| AMI_ID | `ami-02ad619be5bc165df` |
| LAB_READY | Leave unset until ready; then set to `true` |

Before enabling deployment, confirm both Terraform provider lock files are committed. The backend, outputs, deployment permissions, and full-SHA action pins are already implemented.

In GitHub, open **Settings → Secrets and variables → Actions → Variables** and add the table values. Add `LAB_READY=true` last. These are identifiers and configuration, not passwords, so repository variables are appropriate.

## Plan, review, apply

1. Commit and push completed exercises to main. Let Checks pass.
2. Dispatch **Plan lab changes**, operation `deploy`.
3. Inspect the plan log, especially changes to network access, IAM, replacements, and deletion behavior.
4. Copy that successful run ID.
5. Dispatch **Apply reviewed plan**, enter the run ID, operation `deploy`, confirmation `APPLY`.

The plan job packages and uploads source artifacts, then writes the saved Terraform plan and manifest to private S3 under `plans/RUN_ID/`. The apply job verifies the source run, commit, repository, operation, age under 24 hours, target bucket/region, checksum, and Terraform version. Terraform rejects changed backend state. Generate a fresh plan after any code/state change.

Plan/apply use the same concurrency group; applies are never cancelled mid-flight. Repository write permission is required for the manual apply action. If your GitHub plan supports required environment reviewers, enable `environment: lab-dev`, configure main-only environment deployment, and change the apply role's OIDC subject to `repo:OWNER/REPO:environment:lab-dev`.

Saved plans stay out of GitHub artifacts because they can contain secrets. Scope artifact-bucket access and apply short retention to plans. Do not log secret values as nonsensitive Terraform outputs.

## App deployment

After Terraform apply, `scripts/deploy_ec2.py` uses SSM to:

- Download the commit-addressed source archive and verify its SHA256.
- Install locked Python dependencies in a release directory.
- Write nonsecret service configuration and preserve a locally generated signing secret.
- Initialize the schema, switch the current release symlink, and restart systemd.
- Run health, successful-order, receipt, and controlled-failure smoke checks from EC2.

GitHub runners never need inbound access to port 8000. Database passwords are read by the app from Secrets Manager at runtime. A failed app release does not roll back Terraform; inspect the SSM command and deploy a corrected commit. Schema changes beyond initial table creation require explicit migrations.

## Teardown workflow

First stop using the app and follow the data-cleanup checklist in milestone 6. Dispatch **Plan lab changes** with `destroy`, review that plan, then **Apply reviewed plan** with `destroy` and `DESTROY`. It targets only `infra/dev`; bootstrap storage and roles remain.

## Checkpoint and troubleshooting

- Pull-request jobs have no OIDC permission and receive no AWS credentials.
- Plan and apply roles have exact trust subjects.
- A deployment completes SSM smoke tests.
- A stale or mismatched plan is rejected.
- If LAB_READY is unset, deployment jobs intentionally skip.
- If a provider lock file changes during initialization, review and commit it, then re-plan.
- If SSM fails, use its command ID to inspect status, agent connectivity, host packages, and IAM.

## Interview prompts

Why separate plan and apply roles? Why not apply an old reviewed plan after a new commit? Why run smoke tests through SSM instead of opening the app to all GitHub runners?
