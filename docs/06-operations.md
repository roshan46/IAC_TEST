# 6 — Operate, tear down, then consider publishing

## Practice exercises

| Exercise | Action | Expected observation |
| --- | --- | --- |
| Drift | Change a noncritical resource tag in AWS, then run a normal Terraform plan | Plan proposes restoring the configured tag |
| IAM diagnosis | Temporarily remove the receipt worker's bucket write permission | Workflow fails at receipt generation; history/logs identify AccessDenied |
| Retry reasoning | Inspect transient-error retry configuration and simulate a throttling error in a unit test | Transient failures are retryable; controlled fulfillment rejection is terminal |
| Safe rename | Rename one Terraform resource and add a moved block | Plan reports an address move, not a replacement |
| Ambiguous start | Review the adapter test that loses the first start response | The same order UUID is reused |
| Secret rotation | Rotate the DB-managed secret, restart the app, and check health | New connections use the refreshed credential |

Restore intentional fault injections through Terraform and review a fresh plan. Do not leave the app with broken permissions.

## Deliberate teardown

1. Confirm this is the temporary development environment and stop new submissions.
2. Confirm no workflow executions are still running.
3. Decide whether to preserve RDS data. For disposable lab data, explicitly configure skip-final-snapshot behavior. Otherwise set a unique final snapshot identifier and record its ongoing storage cost.
4. Review the receipt bucket's contents. Export anything needed, then deliberately empty it, including versions/delete markers if you enabled versioning. Do not enable blanket force-destroy on bootstrap buckets.
5. Follow the reviewed destroy plan/apply process from milestone 5.
6. Verify the dev state is empty and inspect AWS for remaining EC2, RDS, receipt buckets, workflow resources, log groups, and snapshots.
7. Retain bootstrap state and artifact storage. Old releases and snapshots may still incur storage costs; remove them separately after confirming they are no longer needed.

```bash
terraform -chdir=infra/dev state list
```

Expected result after successful dev teardown: no state entries. Bootstrap state must still list its resources. A nonempty S3 bucket or RDS deletion protection can intentionally block deletion; fix the documented precondition, then generate another destroy plan.

## Later publishing milestone

Do this only after the lab works and you choose to keep paying for hosting.

- Supply a domain or app subdomain you control.
- Create an internet-facing ALB across the two public subnets.
- Issue and validate an ACM certificate in the ALB region.
- Redirect HTTP to HTTPS and route the hostname to the load balancer.
- Replace direct learner-IP app ingress with TCP 8000 from the ALB security group only.
- Add authentication before enabling general public access. For this single-user lab, ALB authentication with a configured Cognito user pool is a suitable extension.
- Retain private RDS and S3. Review logs, retention, budget alerts, and deployment approvals.
- Explain the remaining single EC2/single-AZ database availability limitations.

Do not merely change app ingress to `0.0.0.0/0`: the application has no user accounts or per-user order authorization. HTTPS alone does not supply those controls.

## Checkpoint

Demonstrate a normal deployment, a controlled failure, a safe resource rename, and a complete dev teardown. Include an architecture diagram and a short explanation of the tradeoffs in your portfolio README.

## Interview prompts

What does Terraform not roll back after a failed apply? How would you improve availability? What would change for real payments? Which costs remain after deleting the app?
