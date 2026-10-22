import json
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError
from orderlib.domain import FulfillmentRejected, fulfill_order, receipt_key


class LocalWorkflow:
    """Stateless simulation: never calls AWS; status survives web-worker restarts."""
    def start(self, order):
        return f"local:{order.id}"

    def describe(self, order):
        created = order.created_at
        if created.tzinfo is None:
            created = created.replace(tzinfo=timezone.utc)
        if (datetime.now(timezone.utc) - created).total_seconds() < 2:
            return {"status": "RUNNING"}
        try:
            fulfill_order(order.payload())
        except FulfillmentRejected:
            return {"status": "FAILED", "error": "Controlled demo fulfillment failure"}
        return {"status": "SUCCEEDED", "receipt_key": receipt_key(order.id)}


class AWSWorkflow:
    def __init__(self, state_machine_arn, bucket, client=None, s3=None):
        # This lab uses an unqualified Standard state machine ARN.
        if ":stateMachine:" not in state_machine_arn or len(state_machine_arn.split(":")) != 7:
            raise ValueError("Use an unqualified Standard state machine ARN")
        self.arn = state_machine_arn
        self.bucket = bucket
        self.client = client or boto3.client("stepfunctions")
        self.s3 = s3 or boto3.client("s3")

    def start(self, order):
        payload = json.dumps(order.payload(), sort_keys=True, separators=(",", ":"))
        try:
            return self.client.start_execution(
                stateMachineArn=self.arn, name=order.id, input=payload
            )["executionArn"]
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "ExecutionAlreadyExists":
                raise
            arn = self.arn.replace(":stateMachine:", ":execution:") + ":" + order.id
            previous = self.client.describe_execution(executionArn=arn)
            if json.loads(previous["input"]) != order.payload():
                raise ValueError("Existing execution has different input") from exc
            return arn

    def describe(self, order):
        result = self.client.describe_execution(executionArn=order.execution_arn)
        status = result["status"]
        if status == "SUCCEEDED":
            output = json.loads(result["output"])
            expected = receipt_key(order.id)
            if output.get("receipt_key") != expected:
                return {"status": "FAILED", "error": "Workflow returned an invalid receipt"}
            return {"status": status, "receipt_key": expected}
        if status in {"FAILED", "TIMED_OUT", "ABORTED"}:
            return {"status": "FAILED", "error": "Processing failed. Inspect the workflow execution."}
        return {"status": "RUNNING"}

    def download_url(self, order):
        return self.s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": self.bucket, "Key": receipt_key(order.id),
                    "ResponseContentDisposition": f'attachment; filename="receipt-{order.id}.json"'},
            ExpiresIn=60,
        )
