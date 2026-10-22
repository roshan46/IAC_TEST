import json
from uuid import uuid4
from unittest.mock import Mock
import pytest
from orderlib.domain import InvalidOrder, FulfillmentRejected, validate_order
from workers.validate import handler as validate
from workers.fulfill import handler as fulfill
from workers.receipt import handler as receipt


def event():
    return {"order_id": str(uuid4()), "product": "notebook",
            "quantity": 2, "force_failure": False}


def test_worker_chain_and_retries(monkeypatch):
    s3 = Mock()
    monkeypatch.setenv("RECEIPT_BUCKET", "receipts-test")
    monkeypatch.setattr("workers.receipt.boto3.client", lambda service: s3)
    payload = fulfill(validate(event(), None), None)
    first = receipt(payload, None)
    second = receipt(payload, None)
    assert first == second
    calls = s3.put_object.call_args_list
    assert calls[0] == calls[1]
    assert json.loads(calls[0].kwargs["Body"])["total_cents"] == 2400


def test_failure_and_bad_quantity():
    payload = event()
    payload["force_failure"] = True
    with pytest.raises(FulfillmentRejected):
        fulfill(payload, None)
    payload["quantity"] = True
    with pytest.raises(InvalidOrder):
        validate_order(payload)
