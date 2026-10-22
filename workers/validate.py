from orderlib.domain import validate_order


def handler(event, context):
    return validate_order(event)
