# 4 — Add Lambda and Step Functions

## Goal

Wire supplied business logic into a Standard workflow. This milestone is now implemented in `infra/dev/serverless.tf`; the ASL template and workers are connected to real Terraform resources.

## Current checkpoint: ready to review and apply

The saved `serverless.tfplan` adds **23 resources**: a private receipt bucket and its controls, three Lambda workers with separate roles/log groups, a Standard workflow and its logging/role, and an additional policy on the existing EC2 role. There are **no deletions or replacements**.

The refreshed plan also detects one pre-existing RDS parameter change: `rds.force_ssl` stays `1`, but its apply method changes from AWS's recorded `pending-reboot` to the configuration's `immediate`. Inspect this explicitly in the plan; no database password, storage, instance class, or engine version changes are proposed.

Seven mocked Terraform tests and 22 Python tests pass. AWS's workflow-definition validator returns `OK` with no diagnostics. No new AWS resources or workflow executions have been created by the assistant; the runtime smoke test comes after your apply.

From the project root in PowerShell:

```powershell
$env:AWS_PROFILE = "default"
terraform '-chdir=infra/dev' show serverless.tfplan
terraform '-chdir=infra/dev' apply serverless.tfplan
terraform '-chdir=infra/dev' output workflow_console_url
.venv\Scripts\python.exe scripts/smoke_workflow.py --region us-east-2
```

The smoke test starts two real executions: one succeeds and its JSON receipt is checked, the other deliberately fails and must have no receipt. It prints execution ARNs so you can inspect the steps in the console. The successful test receipt remains in S3 for inspection. The test needs StartExecution/DescribeExecution and S3 read/list access; the local default profile is intended for this milestone.

This adds the backend workflow, not the Flask service. The browser app still requires deployment in milestone 5. Keep `LAB_READY` unset until the GitHub deployment permissions and workflow setup are complete.

## Resource checklist

- Private receipt bucket: encryption and public-access blocking.
- Three Python 3.13 Lambda functions, outside the VPC, timeout 20 seconds.
- Handlers: `workers.validate.handler`, `workers.fulfill.handler`, `workers.receipt.handler`.
- Explicit Lambda log groups with seven-day retention.
- Each Lambda role can write only its own logs. Receipt worker additionally gets PutObject for `receipts/*` in the receipt bucket.
- Receipt worker environment variable: `RECEIPT_BUCKET`.
- Standard Step Functions state machine using `workflow.asl.json.tftpl`.
- State machine execution role: invoke the three exact Lambda ARNs and required log delivery permissions.
- Explicit workflow log group, seven-day retention, and execution logging.
- App role: StartExecution on the state machine, DescribeExecution on its executions, and GetObject on its receipts.

Provide `validate_arn`, `fulfill_arn`, and `receipt_arn` to Terraform `templatefile()`. The template uses JSONPath, passes each Lambda's Payload to the next step, retries transient Lambda service errors, and catches terminal errors into a Fail state.

## Packaging exercise

### Current local setup

There is no local Git commit in this workspace yet. `scripts/package.py --snapshot` creates a deterministic **local source snapshot**, explicitly marked as such in `dist/ID/source.json`. It is not labeled as a Git commit.

The ignored `infra/dev/terraform.tfvars` points `lambda_package_directory` to that snapshot folder. Terraform uses the local ZIP files and calculates their base64 SHA256 values; no S3 artifact upload is needed for this manual milestone. Retain the ZIPs unchanged until you apply the saved plan.

If worker/shared code changes, build a new snapshot and update that input before generating a fresh plan:

```powershell
.venv\Scripts\python.exe scripts/package.py --snapshot
# Use the ID printed by the command above in infra/dev/terraform.tfvars:
# lambda_package_directory = "../../dist/NEW_ID"
terraform '-chdir=infra/dev' plan '-input=false' '-out=serverless.tfplan'
```

### GitHub deployment later

After initializing a local Git repository and committing the project, generate packages:

```bash
python scripts/package.py FULL_40_CHARACTER_COMMIT_SHA
```

Replace the argument with your actual commit SHA. Output is `dist/SHA/`: `app.tar.gz`, three Lambda ZIPs, and `checksums.json`. ZIPs include `workers/` and `orderlib/` at their root. The Lambda runtime supplies boto3.

Upload packages to the bootstrap artifact bucket under `releases/SHA/`. Set each function's S3 bucket/key and `source_code_hash` to the base64 encoding of its SHA256 digest. The milestone 5 helper automates these inputs.

The implemented function resource supports both modes. CI leaves `lambda_package_directory=null` and supplies `release_sha` plus `lambda_hashes`. Do not commit your local package-directory tfvars or `dist/` contents.

## Example execution input

```json
{
  "order_id": "5fd8b99c-ae58-45bb-8fa3-a6a5e38bde22",
  "product": "mug",
  "quantity": 2,
  "force_failure": false
}
```

Successful final output contains `order_id` and `receipt_key`. Change `force_failure` to true and use a new UUID to test failure.

The app uses the order UUID as execution name. Standard StartExecution is idempotent for the same name/input while running. Closed executions return ExecutionAlreadyExists; the adapter describes the existing execution and checks its original input before reusing it. Do not switch this lab to Express without redesigning this behavior. [AWS StartExecution](https://docs.aws.amazon.com/step-functions/latest/apireference/API_StartExecution.html)

Receipt retries write identical bytes to `receipts/ORDER_UUID.json`. This handles a repeated write; it does not establish exactly-once behavior for a future real payment system.

## Checkpoint

- Terraform plan shows three functions and one Standard workflow with scoped roles.
- A successful execution produces a private receipt.
- Controlled failure reaches FAILED; no success receipt is generated.
- Logs and execution history reveal the failed step.
- Worker roles cannot read the database secret or arbitrary buckets.

## Hints and troubleshooting

Import errors usually mean the ZIP directory layout or handler name is wrong. An invocation AccessDenied usually concerns the state machine role; S3 AccessDenied concerns the receipt worker role. Check OutputPath when a downstream worker receives a Lambda response envelope instead of the order.

## Interview prompts

What work belongs in Step Functions versus Lambda? Which errors should be retried? Why is a deterministic receipt key useful? What happens if the caller times out after AWS starts the execution?

Reference: [Step Functions Lambda integration](https://docs.aws.amazon.com/step-functions/latest/dg/connect-lambda.html).

The workflow execution role's log-delivery actions use `Resource="*"` because those CloudWatch APIs do not support resource-level scoping. Lambda invocation, worker log writes, and receipt object access are scoped to this lab's resources. [AWS logging permissions](https://docs.aws.amazon.com/step-functions/latest/dg/cw-logs.html)

Before teardown, stop new executions and deliberately empty the receipt bucket. `force_destroy=false` prevents accidental deletion of receipts when destroying infrastructure.
