# Interface and deployment contracts

## HTTP behavior

| Route | Behavior |
| --- | --- |
| GET /health | Checks database connectivity; 200 when reachable, otherwise 503 |
| GET /orders | Latest 100 orders and a signed create-order form |
| POST /orders | Form fields token, product, quantity, optional force_failure=true; 303 to order detail |
| GET /orders/UUID | Starts pending work or reconciles execution state; renders status |
| GET /orders/UUID/receipt | 409 until successful; local JSON or 303 to a 60-second AWS presigned URL |

Invalid/expired forms return 400. Reusing a token with different details returns 409. Unknown orders return 404. Forms expire after one hour. There is no separate JSON creation API in this lab.

Database states: SUBMITTED, RUNNING, SUCCEEDED, FAILED. Processing progresses on detail/receipt reads, not on a background database poller. An order that is never viewed remains SUBMITTED. A future extension can introduce an outbox dispatcher; the current design keeps the exercise small.

## Environment variables

| Variable | Local | AWS |
| --- | --- | --- |
| APP_SECRET | Explicit local-only development value | Persistent random value in /etc/order-manager-secret.env |
| WORKFLOW_MODE | local | aws |
| DATABASE_URL | PostgreSQL connection string in Compose | Unset |
| DB_HOST | Unused | RDS hostname |
| DB_NAME | Unused | orders |
| DB_SECRET_ARN | Unused | RDS-managed secret ARN |
| STATE_MACHINE_ARN | Unused | Unqualified Standard workflow ARN |
| RECEIPT_BUCKET | Unused | Private receipt bucket name |
| AWS_DEFAULT_REGION | Unused | us-east-2 |

Never store the DB password in Terraform outputs. AWS connection creation retrieves the managed secret and requires TLS. The app caches it for the process lifetime; restart after rotation. Master credentials are used to simplify this temporary lab; a production extension should introduce a least-privilege database user and migrations.

## Dev Terraform outputs

All outputs below are strings, not secret values:

- instance_id: SSM-managed EC2 ID.
- app_url: http://PUBLIC_IP:8000.
- db_host, db_name, db_secret_arn: runtime database configuration.
- state_machine_arn: unqualified Standard state machine ARN.
- receipt_bucket: bucket name, not ARN.
- workflow_console_url: console execution-list link.

Lambda S3 keys are `releases/RELEASE_SHA/validate.zip`, `fulfill.zip`, and `receipt.zip`. Map `lambda_hashes` keys are validate, fulfill, receipt; values are base64 SHA256. App key is `releases/RELEASE_SHA/app.tar.gz`.

For manual milestone 4 deployments, `lambda_package_directory` can instead point to local ZIPs relative to `infra/dev`. In that mode Terraform uploads the ZIPs directly and computes their hashes. Local source snapshot IDs are documented as content IDs, not Git commits. CI keeps this variable null and uses the S3 contract above.

## IAM permission exercise

| Identity | Required capability | Boundary |
| --- | --- | --- |
| EC2 app role | SSM managed-node operations | Standard SSM managed-node policy plus appropriate network access |
| EC2 app role | secretsmanager:GetSecretValue | Exact RDS-managed secret |
| EC2 app role | states:StartExecution | Exact workflow |
| EC2 app role | states:DescribeExecution | Executions of that workflow only |
| EC2 app role | s3:GetObject | Receipt prefix and release prefix in their respective buckets |
| Validate/fulfill Lambda roles | Log writes | Their own log groups |
| Receipt Lambda role | Log writes and s3:PutObject | Own logs and receipt prefix |
| State machine role | lambda:InvokeFunction | Three worker ARNs |
| State machine role | Log delivery | AWS-required CloudWatch delivery actions; document actions requiring wildcard resources |
| Plan role | Terraform resource reads, state read/write and lock operations | Lab resources and dev state key; metadata/list APIs may require wildcard resources |
| Plan role | Artifact PutObject/GetObject | releases/ and plans/ in the artifact bucket |
| Apply role | Resource CRUD, IAM PassRole, state/lock access | Lab resources/roles; do not grant unrestricted account administration |
| Apply role | Artifact reads and SSM command operations | Reviewed artifacts, AWS-RunShellScript, and the lab instance |

Neither dev workflow role should change bootstrap resources or bootstrap state. Include KMS permissions only if you choose customer-managed keys. Attach permissions boundaries or restrict IAM role creation/PassRole to the project's role path as a further exercise.

## Deliberate limitations

One application instance, no automatic database schema migration, no authentication until publishing, no continuous status reconciliation, and no automatic infrastructure rollback. Retry safety covers the simulated fulfillment and deterministic receipt writes, not arbitrary future side effects.
