"""Deploy reviewed source to an SSM-managed Ubuntu host and smoke-test locally."""
import base64
import json
import re
import shlex
import time
import boto3


def deploy(outputs, bucket, revision, checksum):
    values = {key: outputs[key]["value"] for key in (
        "instance_id", "db_host", "db_name", "db_secret_arn", "state_machine_arn", "receipt_bucket")}
    if not re.fullmatch(r"[0-9a-f]{40}", revision) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Invalid release identity")
    region = boto3.session.Session().region_name
    environment = {
        "WORKFLOW_MODE": "aws", "AWS_DEFAULT_REGION": region,
        "DB_HOST": values["db_host"], "DB_NAME": values["db_name"],
        "DB_SECRET_ARN": values["db_secret_arn"],
        "STATE_MACHINE_ARN": values["state_machine_arn"], "RECEIPT_BUCKET": values["receipt_bucket"],
    }
    # JSON quoting is also valid for these simple systemd EnvironmentFile values.
    config = "\n".join(f"{k}={json.dumps(v)}" for k,
                       v in environment.items()) + "\n"
    encoded = base64.b64encode(config.encode()).decode()
    unit = """[Unit]
Description=Order Manager lab
After=network-online.target
Wants=network-online.target
[Service]
User=orderapp
Group=orderapp
WorkingDirectory=/opt/order-manager/current
EnvironmentFile=/etc/order-manager.env
EnvironmentFile=/etc/order-manager-secret.env
ExecStart=/opt/order-manager/current/.venv/bin/gunicorn --bind 0.0.0.0:8000 --workers 2 'app:create_app()'
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
"""
    unit64 = base64.b64encode(unit.encode()).decode()
    target = "/opt/order-manager/releases/" + revision
    uri = f"s3://{bucket}/releases/{revision}/app.tar.gz"
    command = f"""set -eu
command -v aws
command -v uv
id orderapp
install -d -m 755 {target}
aws s3 cp {shlex.quote(uri)} /tmp/order-manager-release.tar.gz --only-show-errors
echo '{checksum}  /tmp/order-manager-release.tar.gz' | sha256sum -c -
tar -xzf /tmp/order-manager-release.tar.gz -C {target}
printf '%s' '{encoded}' | base64 -d > /etc/order-manager.env
chmod 600 /etc/order-manager.env
if [ ! -s /etc/order-manager-secret.env ]; then
  python3 -c 'import secrets; print("APP_SECRET=" + secrets.token_hex(32))' > /etc/order-manager-secret.env
fi
chown root:orderapp /etc/order-manager.env /etc/order-manager-secret.env
chmod 640 /etc/order-manager.env /etc/order-manager-secret.env
chown -R orderapp:orderapp {target}
runuser -u orderapp -- sh -c 'cd {target} && uv sync --frozen --no-dev --no-install-project'
set -a
. /etc/order-manager.env
. /etc/order-manager-secret.env
set +a
cd {target}
runuser -u orderapp --preserve-environment -- .venv/bin/flask --app app init-db
ln -sfn {target} /opt/order-manager/current
printf '%s' '{unit64}' | base64 -d > /etc/systemd/system/order-manager.service
systemctl daemon-reload
systemctl enable order-manager
systemctl restart order-manager
for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8000/health; then break; fi
  sleep 2
done
python3 {target}/scripts/smoke.py
"""
    ssm = boto3.client("ssm")
    result = ssm.send_command(
        InstanceIds=[values["instance_id"]], DocumentName="AWS-RunShellScript",
        Parameters={"commands": [command], "executionTimeout": ["900"]},
        TimeoutSeconds=900, Comment="Order Manager reviewed release " + revision)
    command_id = result["Command"]["CommandId"]
    for _ in range(180):
        time.sleep(5)
        try:
            invocation = ssm.get_command_invocation(CommandId=command_id,
                                                    InstanceId=values["instance_id"])
        except ssm.exceptions.InvocationDoesNotExist:
            continue
        if invocation["Status"] == "Success":
            print("SSM deployment and smoke tests passed:", command_id)
            return
        if invocation["Status"] in {"Failed", "Cancelled", "TimedOut"}:
            raise RuntimeError(
                f"SSM deployment failed ({command_id}); inspect command output in AWS")
    raise TimeoutError(
        "SSM deployment did not finish; inspect command " + command_id)
