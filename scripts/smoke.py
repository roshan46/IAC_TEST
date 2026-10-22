"""Run on the EC2 host through SSM; runner IP need not access the app."""
import re
import time
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:8000"


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=15) as response:
        return response.read().decode()


def run(failure=False):
    page = get("/orders")
    token = re.search(r'name="token" value="([^"]+)"', page).group(1)
    data = urllib.parse.urlencode({
        "token": token, "product": "mug", "quantity": "1",
        "force_failure": "true" if failure else "false",
    }).encode()
    with urllib.request.urlopen(BASE + "/orders", data=data, timeout=30) as response:
        location = urllib.parse.urlparse(response.url).path
    for _ in range(60):
        page = get(location)
        if "SUCCEEDED" in page:
            if failure:
                raise RuntimeError("Failure scenario unexpectedly succeeded")
            if '"demo_only": true' not in get(location + "/receipt"):
                raise RuntimeError("Receipt missing")
            return
        if "FAILED" in page:
            if not failure:
                raise RuntimeError("Success scenario failed")
            return
        time.sleep(2)
    raise RuntimeError("Workflow did not finish within smoke-test timeout")


if __name__ == "__main__":
    assert '"ok"' in get("/health")
    run()
    run(failure=True)
    print("PASS: health, successful receipt, controlled failure")
