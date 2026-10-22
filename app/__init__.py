import json
import os
from uuid import uuid4

import boto3
import click
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, abort, g, redirect, render_template, request, url_for, Response
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from sqlalchemy import create_engine, select, text
from sqlalchemy.engine import URL
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import sessionmaker

from app.models import Base, Order
from app.workflow import AWSWorkflow, LocalWorkflow
from orderlib.domain import InvalidOrder, PRODUCTS, receipt_bytes, validate_order


def database_url(config):
    if config.get("DATABASE_URL"):
        return config["DATABASE_URL"]
    secret = json.loads(boto3.client("secretsmanager").get_secret_value(
        SecretId=config["DB_SECRET_ARN"])["SecretString"])
    return URL.create("postgresql+psycopg", username=secret["username"],
                      password=secret["password"], host=config["DB_HOST"],
                      port=5432, database=config.get("DB_NAME", "orders"),
                      query={"sslmode": "require"})


def create_app(config=None):
    app = Flask(__name__)
    app.config.from_mapping(
        SECRET_KEY=os.environ.get("APP_SECRET"),
        DATABASE_URL=os.environ.get("DATABASE_URL"),
        DB_SECRET_ARN=os.environ.get("DB_SECRET_ARN"),
        DB_HOST=os.environ.get("DB_HOST"), DB_NAME=os.environ.get("DB_NAME", "orders"),
        WORKFLOW_MODE=os.environ.get("WORKFLOW_MODE", "local"),
        STATE_MACHINE_ARN=os.environ.get("STATE_MACHINE_ARN"),
        RECEIPT_BUCKET=os.environ.get("RECEIPT_BUCKET"),
        MAX_CONTENT_LENGTH=16 * 1024,
    )
    if config:
        app.config.update(config)
    if not app.config["SECRET_KEY"]:
        raise ValueError("APP_SECRET must be set")
    mode = app.config["WORKFLOW_MODE"]
    if mode not in {"local", "aws"}:
        raise ValueError("WORKFLOW_MODE must be local or aws")
    engine = create_engine(database_url(app.config), pool_pre_ping=True)
    app.extensions["engine"] = engine
    sessions = sessionmaker(engine, expire_on_commit=False)
    workflow = app.config.get("WORKFLOW") or (
        LocalWorkflow() if mode == "local" else
        AWSWorkflow(app.config["STATE_MACHINE_ARN"], app.config["RECEIPT_BUCKET"]))
    app.extensions["workflow"] = workflow
    signer = URLSafeTimedSerializer(app.config["SECRET_KEY"], salt="create-order")

    def db():
        if "db" not in g:
            g.db = sessions()
        return g.db

    @app.teardown_appcontext
    def close_db(error=None):
        session = g.pop("db", None)
        if session:
            session.close()

    @app.cli.command("init-db")
    def init_db():
        """Create the initial schema; future changes require explicit migrations."""
        Base.metadata.create_all(engine)
        click.echo("Database schema ready")

    @app.get("/health")
    def health():
        try:
            db().execute(text("SELECT 1"))
        except SQLAlchemyError:
            return {"status": "unhealthy"}, 503
        return {"status": "ok", "workflow_mode": mode}

    @app.get("/")
    def home():
        return redirect(url_for("orders"))

    @app.get("/orders")
    def orders():
        rows = db().scalars(select(Order).order_by(Order.created_at.desc()).limit(100)).all()
        return render_template("orders.html", orders=rows, products=PRODUCTS,
                               token=signer.dumps(str(uuid4())), mode=mode)

    @app.post("/orders")
    def create_order():
        try:
            order_id = signer.loads(request.form.get("token", ""), max_age=3600)
            failure = request.form.get("force_failure", "false")
            if failure not in {"true", "false"}:
                raise ValueError("Invalid failure flag")
            payload = validate_order({
                "order_id": order_id, "product": request.form.get("product"),
                "quantity": int(request.form.get("quantity", "")),
                "force_failure": failure == "true"})
        except (BadSignature, SignatureExpired, ValueError, TypeError, InvalidOrder):
            abort(400, "Invalid order or expired form. Reload the orders page.")
        values = {key: payload[key] for key in ("product", "quantity", "force_failure")}
        session = db()
        order = Order(id=order_id, **values)
        session.add(order)
        try:
            session.commit()  # Persist intent BEFORE starting an external workflow.
        except IntegrityError:
            session.rollback()
            existing = session.get(Order, order_id)
            if existing is None or any(getattr(existing, key) != value for key, value in values.items()):
                abort(409, "This form was already used for different order details.")
        return redirect(url_for("order_detail", order_id=order_id), code=303)

    def reconcile(order_id):
        session = db()
        # Serialize concurrent detail requests, including recovery of an ambiguous start.
        order = session.scalar(select(Order).where(Order.id == order_id).with_for_update())
        if order is None:
            abort(404)
        warning = None
        if order.status in {"SUBMITTED", "RUNNING"}:
            try:
                if not order.execution_arn:
                    order.execution_arn = workflow.start(order)
                    order.status = "RUNNING"
                result = workflow.describe(order)
                order.status = result["status"]
                order.receipt_key = result.get("receipt_key")
                order.error = result.get("error")
            except (BotoCoreError, ClientError):
                warning = "AWS is temporarily unavailable. Refresh to retry this same order."
            session.commit()
        return order, warning

    @app.get("/orders/<uuid:order_id>")
    def order_detail(order_id):
        order, warning = reconcile(str(order_id))
        return render_template("detail.html", order=order, warning=warning, mode=mode)

    @app.get("/orders/<uuid:order_id>/receipt")
    def receipt(order_id):
        order, warning = reconcile(str(order_id))
        if order.status != "SUCCEEDED" or not order.receipt_key:
            abort(409, "A receipt is available only after successful processing.")
        if mode == "local":
            return Response(receipt_bytes(order.payload()), mimetype="application/json",
                            headers={"Content-Disposition": f'attachment; filename="receipt-{order.id}.json"'})
        return redirect(workflow.download_url(order), code=303)

    @app.after_request
    def security_headers(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self'; form-action 'self'; frame-ancestors 'none'"
        return response

    return app
