# 1 — Run and understand the app

## Goal

Make the application work before learning cloud deployment. Docker Compose supplies PostgreSQL 17 and a Flask/Gunicorn container. Port 8000 binds only to your local machine; PostgreSQL has no host port.

## Steps

```bash
docker compose up --build -d
docker compose ps
docker compose logs app
```

Visit http://localhost:8000/orders. Create a notebook order, open it, wait two seconds, refresh, and download the JSON receipt. Then create an order with controlled failure enabled.

The simulator derives completion from order creation time and reuses the worker domain functions. It is not a background process or an emulation of AWS retries. The same persisted order works across web-worker restarts.

```bash
uv sync --frozen --extra dev
uv run pytest -q
```

Run the full suite against a separate, disposable PostgreSQL instance:

```bash
docker compose -p order-manager-lab-tests -f compose.test.yaml up --build --abort-on-container-exit --exit-code-from tests
docker compose -p order-manager-lab-tests -f compose.test.yaml down
```

The test database uses temporary memory-backed storage and does not touch your demo orders.

Optional live smoke test from your computer while Compose is running:

```bash
uv run python scripts/smoke.py
```

## Understand the code

Read `app/models.py`, `app/__init__.py`, `app/workflow.py`, and `orderlib/domain.py`.

A signed, one-hour form token contains a pre-generated order UUID. Posting the same form again returns the same order; changing its values returns HTTP 409. The database commit happens before any external workflow call. The detail page starts/reconciles processing, allowing a later refresh to recover an interrupted start.

Receipt amounts use integer cents. No real payment or fulfillment occurs. Successful receipts are deterministic.

## Checkpoint

- Health returns HTTP 200 and workflow mode `local`.
- Success persists as SUCCEEDED in PostgreSQL and produces a receipt.
- Failure persists as FAILED and its receipt route returns HTTP 409.
- Submitting the same form twice produces only one database row.
- Restarting the app retains orders.

## Troubleshooting and hints

- Database startup errors: inspect `docker compose logs db`; Compose waits for database health.
- Port conflict: change only the host side of `127.0.0.1:8000:8000`, and update your browser/smoke-test URL.
- Expired form: refresh the order list to obtain a new token.
- Database schema creation is idempotent but is not a schema migration system.
- For a local reset, deliberately run `docker compose down --volumes`, then start again.

## Interview prompts

Why save an order before calling an external API? Why use cents rather than floating-point prices? What happens if the HTTP response is lost after the order is committed?
