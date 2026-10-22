import json
from types import SimpleNamespace
from uuid import uuid4
from unittest.mock import Mock
import pytest
from botocore.exceptions import ClientError
from app.workflow import AWSWorkflow
from orderlib.domain import receipt_key


def setup():
    order_id = str(uuid4())
    payload = {"order_id": order_id, "product": "mug", "quantity": 1, "force_failure": False}
    order = SimpleNamespace(id=order_id, payload=lambda: payload,
                            execution_arn="arn:aws:states:us-east-2:123456789012:execution:orders:" + order_id)
    client, s3 = Mock(), Mock()
    adapter = AWSWorkflow("arn:aws:states:us-east-2:123456789012:stateMachine:orders",
                          "receipts-test", client, s3)
    return order, client, s3, adapter


def test_closed_execution_recovery_checks_input():
    order, client, _, adapter = setup()
    client.start_execution.side_effect = ClientError(
        {"Error": {"Code": "ExecutionAlreadyExists", "Message": "exists"}}, "StartExecution")
    client.describe_execution.return_value = {"input": json.dumps(order.payload())}
    assert adapter.start(order) == order.execution_arn
    client.describe_execution.return_value = {"input": "{}"}
    with pytest.raises(ValueError):
        adapter.start(order)


def test_success_and_presigned_expiry():
    order, client, s3, adapter = setup()
    client.describe_execution.return_value = {
        "status": "SUCCEEDED", "output": json.dumps({"receipt_key": receipt_key(order.id)})}
    assert adapter.describe(order)["status"] == "SUCCEEDED"
    adapter.download_url(order)
    assert s3.generate_presigned_url.call_args.kwargs["ExpiresIn"] == 60


@pytest.mark.parametrize("status", ["FAILED", "TIMED_OUT", "ABORTED"])
def test_terminal_failure(status):
    order, client, _, adapter = setup()
    client.describe_execution.return_value = {"status": status}
    assert adapter.describe(order)["status"] == "FAILED"
