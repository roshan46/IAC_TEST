import re
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from sqlalchemy import select, func
from sqlalchemy.orm import Session
from botocore.exceptions import EndpointConnectionError
from app.models import Order


def form(client, **changes):
    html = client.get("/orders").text
    token = re.search(r'name="token" value="([^"]+)"', html).group(1)
    return {"token": token, "product": "mug", "quantity": "2", **changes}


def age_order(app, location):
    with Session(app.extensions["engine"]) as session:
        row = session.get(Order, location.rsplit("/", 1)[1])
        row.created_at = datetime.now(timezone.utc) - timedelta(seconds=5)
        session.commit()


def test_success_persists_and_receipt_is_deterministic(app, client):
    response = client.post("/orders", data=form(client))
    assert response.status_code == 303
    location = response.headers["Location"]
    assert "RUNNING" in client.get(location).text
    assert client.get(location + "/receipt").status_code == 409
    age_order(app, location)
    assert "SUCCEEDED" in client.get(location).text
    first = client.get(location + "/receipt")
    assert first.status_code == 200
    assert first.json["total_cents"] == 3600
    assert first.data == client.get(location + "/receipt").data
    with Session(app.extensions["engine"]) as session:
        assert session.get(Order, location.rsplit("/", 1)[1]).status == "SUCCEEDED"


def test_duplicate_form_is_one_order(app, client):
    data = form(client)
    one = client.post("/orders", data=data)
    two = client.post("/orders", data=data)
    assert one.headers["Location"] == two.headers["Location"]
    with Session(app.extensions["engine"]) as session:
        assert session.scalar(select(func.count()).select_from(Order)) == 1
    data["quantity"] = "3"
    assert client.post("/orders", data=data).status_code == 409


@pytest.mark.parametrize("changes", [
    {"quantity": "0"}, {"quantity": "11"}, {"quantity": "abc"},
    {"product": "unknown"}, {"token": "forged"}, {"force_failure": "bad"},
])
def test_invalid_orders(client, changes):
    assert client.post("/orders", data=form(client, **changes)).status_code == 400


def test_failure_has_no_receipt(app, client):
    response = client.post("/orders", data=form(client, force_failure="true"))
    location = response.headers["Location"]
    age_order(app, location)
    page = client.get(location)
    assert "FAILED" in page.text
    assert "Controlled demo" in page.text
    assert client.get(location + "/receipt").status_code == 409


def test_health_and_unknown_order(client):
    assert client.get("/health").json["status"] == "ok"
    assert client.get(f"/orders/{uuid4()}").status_code == 404


def test_ambiguous_start_retries_same_identity(app, client):
    delegate = app.extensions["workflow"]
    original = delegate.start
    calls = []

    def start(order):
        calls.append(order.id)
        if len(calls) == 1:
            raise EndpointConnectionError(endpoint_url="https://example.invalid")
        return original(order)

    delegate.start = start
    location = client.post("/orders", data=form(client)).headers["Location"]
    assert "temporarily unavailable" in client.get(location).text
    assert "RUNNING" in client.get(location).text
    assert len(calls) == 2 and calls[0] == calls[1]


def test_expired_form(app, client, monkeypatch):
    data = form(client)
    monkeypatch.setattr("itsdangerous.timed.TimestampSigner.get_timestamp", lambda self: 9999999999)
    assert client.post("/orders", data=data).status_code == 400
