# 2 — Bootstrap state and GitHub identity

## Goal and prerequisites

Use your own AWS account, a new globally unique state bucket name, a separate artifact bucket name, and a new GitHub repository name. Authenticate locally with a short-lived AWS session. Do not copy credentials or bucket names from the existing projects.

Bootstrap is now implemented in `infra/bootstrap/main.tf`; application resources in `infra/dev/` remain exercises. Your ignored local inputs target `roshan46/IAC_TEST`, account `848005667541`, and region `us-east-2`, using the AWS `default` profile. The existing GitHub OIDC provider is read without adopting or modifying it.

The new repository uses the immutable-ID subject format. Local inputs include owner ID `8665938` and repository ID `1429116069`. Legacy repositories can leave both IDs null after verifying their subject format. [GitHub OIDC guidance](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)

## Current checkpoint: plan ready, not applied

Validation and five mocked Terraform tests passed. The saved AWS plan has **18 additions, 0 changes, 0 deletions**. It creates two buckets and controls, two roles, and four storage policies. No AWS resources have been created yet.

From the project root in PowerShell:

```powershell
$env:AWS_PROFILE = "default"
aws sts get-caller-identity
terraform '-chdir=infra/bootstrap' show bootstrap.tfplan
# After reviewing, apply the saved plan:
terraform '-chdir=infra/bootstrap' apply bootstrap.tfplan
```

If inputs/code changed, regenerate the plan first:

```powershell
terraform '-chdir=infra/bootstrap' plan '-input=false' '-out=bootstrap.tfplan'
```

Quote flags containing filenames in PowerShell to avoid argument-parsing problems.

## Resource checklist

- State S3 bucket: versioning, encryption, public-access block, and `prevent_destroy`.
- Artifact S3 bucket: private, encrypted, public-access blocked. Expire `plans/` objects after two days; retain releases until deliberate cleanup.
- GitHub OIDC provider with audience `sts.amazonaws.com`, created or explicitly reused.
- Separate plan/apply roles trusting only the exact repository main-branch subject, including IDs when applicable.
- Baseline scoped state/artifact permissions: plan publishes artifacts; apply reads them. Both use only dev state/locking; bootstrap state access is explicitly denied.
- Outputs: `state_bucket_name`, `artifact_bucket_name`, `github_plan_role_arn`, `github_apply_role_arn`.

For another account, set `existing_github_oidc_provider_arn` to reuse its GitHub provider, or null to create one. The code verifies its URL and audience.

Milestone 2 intentionally starts the roles with state and artifact access only. Milestone 5 adds the reviewed application permissions in `deployment-permissions.tf` after the resource names and deployment flow are known. Leave `LAB_READY` unset until that later bootstrap update has been applied.

## Local state first

For a fresh checkout, copy `terraform.tfvars.example` to ignored `terraform.tfvars` and replace placeholders. Your current local inputs are already populated. Initialize and inspect:

```bash
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap fmt
terraform -chdir=infra/bootstrap validate
terraform -chdir=infra/bootstrap plan -out=bootstrap.tfplan
terraform -chdir=infra/bootstrap apply bootstrap.tfplan
```

Expected plan: new S3, IAM, and OIDC resources only. No deletions or changes to existing projects. An empty plan means the exercise is unfinished.

After the bucket exists, activate the supplied backend. Your ignored `backend.s3.tfbackend` is already populated. For a different account, copy the example and replace the bucket name first.

```powershell
Copy-Item infra/bootstrap/backend.tf.example infra/bootstrap/backend.tf
terraform '-chdir=infra/bootstrap' init -migrate-state '-backend-config=backend.s3.tfbackend'
```

Confirm the state-copy prompt only after checking the destination bucket. Retain local state until migration succeeds. Commit `backend.tf` after migration; the bucket-name configuration file stays ignored. Do not reuse the initial saved local-backend plan after migration.

```bash
terraform -chdir=infra/bootstrap state list
terraform -chdir=infra/bootstrap plan
```

Confirm migration and a no-change plan. Commit `.terraform.lock.hcl`; keep state, plans, real tfvars, and backend files out of Git. Bootstrap state key is `bootstrap/terraform.tfstate`; dev uses a different key.

Native locking is enabled by `use_lockfile=true`. The lock object needs GetObject, PutObject, and DeleteObject permissions; DynamoDB locking is deprecated. [HashiCorp S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)

## Checkpoint

- State is in the intended bucket/key; versioning and public-access blocking are enabled.
- Remote plan works; lock-object permissions are correct.
- IAM trust limits repository and main branch, not every GitHub repository.
- Bootstrap resources remain independent from the dev application's state.

## Hints and troubleshooting

Use `aws_caller_identity` to build account-specific names and ARNs. Keep backend configuration separate from normal variables. Backend initialization cannot depend on a resource it has not created yet. If OIDC fails later, compare the exact token subject with the trust policy; an environment-based job has a different subject.

## Interview prompts

Why separate bootstrap state? How does the provider lock file differ from backend locking? Why does a plan role need write permission to a lock object?

Reference: [GitHub OIDC on AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws).

## Credential-free verification

```powershell
terraform '-chdir=infra/bootstrap' fmt -check -recursive
terraform '-chdir=infra/bootstrap' validate
terraform '-chdir=infra/bootstrap' test
```

Tests use `mock_provider "aws"`; test applies create no real resources. They verify storage access, branch-scoped trust, immutable IDs, reuse of an existing provider, and invalid inputs.
