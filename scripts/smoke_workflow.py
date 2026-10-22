"""After milestone 4 apply: exercise real AWS workflows without deploying Flask."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from uuid import uuid4

import boto3
from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]


def wait(client, arn):
    deadline = time.monotonic() + 210
    while time.monotonic() < deadline:
        result = client.describe_execution(executionArn=arn)
        if result["status"] != "RUNNING":
            return result
        time.sleep(2)
    raise TimeoutError(f"Execution not finished: {arn}")


def smoke(region):
    result = subprocess.run(
        ["terraform", "-chdir=infra/dev", "output", "-json"],
        cwd=ROOT, check=True, text=True, capture_output=True)
    outputs = json.loads(result.stdout)
    state_machine = outputs["state_machine_arn"]["value"]
    bucket = outputs["receipt_bucket"]["value"]
    client = boto3.client("stepfunctions", region_name=region)
    s3 = boto3.client("s3", region_name=region)

    for failure in (False, True):
        order_id = str(uuid4())
        payload = {"order_id": order_id, "product": "mug", "quantity": 2,
                   "force_failure": failure}
        arn = client.start_execution(
            stateMachineArn=state_machine, name=order_id,
            input=json.dumps(payload, sort_keys=True))["executionArn"]
        print("Checking", arn, flush=True)
        execution = wait(client, arn)
        expected = "FAILED" if failure else "SUCCEEDED"
        if execution["status"] != expected:
            raise RuntimeError(f"Expected {expected}; got {execution['status']}. Inspect {arn}")
        key = f"receipts/{order_id}.json"
        if failure:
            try:
                s3.head_object(Bucket=bucket, Key=key)
            except ClientError as exc:
                if exc.response["Error"]["Code"] not in {"404", "NoSuchKey", "NotFound"}:
                    raise
            else:
                raise RuntimeError("Failed order unexpectedly has a receipt")
        else:
            output = json.loads(execution["output"])
            if output.get("receipt_key") != key:
                raise RuntimeError("Workflow returned the wrong receipt key")
            receipt = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
            if receipt.get("order_id") != order_id or receipt.get("total_cents") != 3600:
                raise RuntimeError("Receipt contents do not match the order")
            print("Receipt verified:", key, flush=True)
    print("PASS: successful receipt and controlled failure without a receipt")
    print("The successful test receipt remains in S3; empty the bucket deliberately before teardown.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", default="us-east-2")
    smoke(parser.parse_args().region)
