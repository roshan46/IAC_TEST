import os
import boto3
from orderlib.domain import receipt_bytes, receipt_key


def handler(event, context):
    key = receipt_key(event["order_id"])
    # Repeated invocations overwrite the same key with identical bytes.
    boto3.client("s3").put_object(
        Bucket=os.environ["RECEIPT_BUCKET"], Key=key,
        Body=receipt_bytes(event), ContentType="application/json",
        ServerSideEncryption="AES256",
    )
    return {"order_id": event["order_id"], "receipt_key": key}
