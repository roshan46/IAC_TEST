"""Pure domain functions shared by Flask, the simulator, and Lambda."""
import json
from uuid import UUID

PRODUCTS = {"notebook": 1200, "mug": 1800, "sticker-pack": 500}


class InvalidOrder(ValueError):
    pass


class FulfillmentRejected(ValueError):
    pass


def validate_order(event):
    try:
        order_id = str(UUID(event["order_id"]))
        product = event["product"]
        quantity = event["quantity"]
        force_failure = event.get("force_failure", False)
        if product not in PRODUCTS:
            raise ValueError("Unknown product")
        if type(quantity) is not int or not 1 <= quantity <= 10:
            raise ValueError("Quantity must be an integer from 1 to 10")
        if type(force_failure) is not bool:
            raise ValueError("Failure flag must be boolean")
    except (KeyError, TypeError, ValueError) as exc:
        raise InvalidOrder(str(exc)) from exc
    return {"order_id": order_id, "product": product, "quantity": quantity,
            "force_failure": force_failure,
            "total_cents": PRODUCTS[product] * quantity}


def fulfill_order(event):
    order = validate_order(event)
    if order["force_failure"]:
        raise FulfillmentRejected("Controlled demo fulfillment failure")
    return {**order, "fulfilled": True}


def receipt_key(order_id):
    return f"receipts/{UUID(order_id)}.json"


def receipt_bytes(event):
    order = fulfill_order(event)
    receipt = {key: order[key] for key in
               ("order_id", "product", "quantity", "total_cents")}
    receipt["currency"] = "USD"
    receipt["demo_only"] = True
    return (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode()
