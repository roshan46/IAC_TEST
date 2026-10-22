from orderlib.domain import fulfill_order


def handler(event, context):
    return fulfill_order(event)
