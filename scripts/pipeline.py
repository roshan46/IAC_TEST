"""Trusted-main CI helper. Infrastructure remains a learner exercise."""
import base64
from datetime import datetime, timezone, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

import boto3
from package import build

ROOT = Path(__file__).resolve().parents[1]
INFRA = ROOT / "infra" / "dev"
PLAN = ROOT / ".plan"


def run(*args, capture=False):
    return subprocess.run(args, cwd=ROOT, check=True, text=True,
                          capture_output=capture).stdout


def tf(*args, capture=False):
    return run("terraform", "-chdir=infra/dev", *args, capture=capture)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_environment():
    required = ("STATE_BUCKET", "ARTIFACT_BUCKET", "AWS_REGION", "GITHUB_SHA",
                "GITHUB_REPOSITORY", "LEARNER_CIDR", "AMI_ID")
    for key in required:
        if not os.environ.get(key):
            raise ValueError(f"Missing {key}")
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Deployment workflows must run from main")
    if not re.fullmatch(r"[0-9a-f]{40}", os.environ["GITHUB_SHA"]):
        raise ValueError("Invalid commit SHA")
    PLAN.mkdir(exist_ok=True)


def initialize():
    tf("init", "-input=false",
       "-backend-config", "bucket=" + os.environ["STATE_BUCKET"],
       "-backend-config", "key=dev/order-manager/terraform.tfstate",
       "-backend-config", "region=" + os.environ["AWS_REGION"],
       "-backend-config", "encrypt=true",
       "-backend-config", "use_lockfile=true")
    if not (INFRA / ".terraform.lock.hcl").exists():
        raise ValueError("Commit the initialized provider lock file before CI deployment")
    # Fail if init altered the reviewed provider selection.
    run("git", "diff", "--exit-code", "--", "infra/dev/.terraform.lock.hcl")
    tracked = run("git", "ls-files", "infra/dev/.terraform.lock.hcl", capture=True).strip()
    if not tracked:
        raise ValueError("Provider lock file must be tracked in Git")


def check_ready():
    files = "\n".join(p.read_text() for p in INFRA.glob("*.tf"))
    if not re.search(r'backend\s+"s3"\s*\{', re.sub(r"(?m)#.*$", "", files)):
        raise ValueError("Complete the S3 backend exercise first")
    # Modules are allowed. The plan-level check below is the authoritative resource check.


def make_plan(operation):
    require_environment()
    check_ready()
    initialize()
    revision = os.environ["GITHUB_SHA"]
    bucket = os.environ["ARTIFACT_BUCKET"]
    s3 = boto3.client("s3")
    release = build(revision)
    checksums = json.loads((release / "checksums.json").read_text())
    for name in checksums:
        s3.upload_file(str(release / name), bucket, f"releases/{revision}/{name}")
    values = {
        "aws_region": os.environ["AWS_REGION"],
        "learner_cidr": os.environ["LEARNER_CIDR"],
        "artifact_bucket": bucket, "release_sha": revision,
        "ami_id": os.environ["AMI_ID"],
        "lambda_hashes": {
            name: base64.b64encode(bytes.fromhex(checksums[f"{name}.zip"])).decode()
            for name in ("validate", "fulfill", "receipt")
        },
    }
    variables = PLAN / "inputs.tfvars.json"
    variables.write_text(json.dumps(values))
    plan = PLAN / "deployment.tfplan"
    args = ["plan", "-input=false", "-lock-timeout=60s",
            "-var-file=" + str(variables), "-out=" + str(plan)]
    if operation == "destroy":
        args.append("-destroy")
    tf(*args)
    document = json.loads(tf("show", "-json", str(plan), capture=True))
    resources = [r for r in document.get("resource_changes", []) if r.get("mode") == "managed"]
    if not resources:
        raise ValueError("No managed resources found; finish the Terraform exercises first")
    manifest = {
        "sha": revision, "repository": os.environ["GITHUB_REPOSITORY"],
        "operation": operation, "created_at": datetime.now(timezone.utc).isoformat(),
        "terraform_version": document["terraform_version"],
        "plan_sha256": digest(plan), "app_sha256": checksums["app.tar.gz"],
        "artifact_bucket": bucket, "state_bucket": os.environ["STATE_BUCKET"],
        "region": os.environ["AWS_REGION"],
        "learner_cidr": os.environ["LEARNER_CIDR"],
        "ami_id": os.environ["AMI_ID"],
    }
    run_id = os.environ["GITHUB_RUN_ID"]
    prefix = f"plans/{run_id}"
    # Saved plans can contain secrets: never upload these as public GitHub artifacts.
    s3.upload_file(str(plan), bucket, prefix + "/deployment.tfplan")
    s3.put_object(Bucket=bucket, Key=prefix + "/manifest.json",
                  Body=json.dumps(manifest).encode(), ContentType="application/json")
    summary = f"\nPlan run: {run_id}\nCommit: {revision}\nOperation: {operation}\n"
    summary += "Review the Terraform plan log, then manually run Apply reviewed plan with this run ID.\n"
    with open(os.environ.get("GITHUB_STEP_SUMMARY", PLAN / "summary.txt"), "a") as output:
        output.write(summary)


def validate_manifest(manifest, revision, repository, operation, now=None):
    if manifest["sha"] != revision or manifest["repository"] != repository:
        raise ValueError("Plan commit/repository does not match current main")
    if manifest["operation"] != operation:
        raise ValueError("Plan operation mismatch")
    created = datetime.fromisoformat(manifest["created_at"])
    now = now or datetime.now(timezone.utc)
    age = now - created
    if age < timedelta(0) or age > timedelta(hours=24):
        raise ValueError("Plan expired; generate and review a fresh plan")


def verify_run(run_id):
    if not re.fullmatch(r"[0-9]+", run_id):
        raise ValueError("Invalid plan run ID")
    repository = os.environ["GITHUB_REPOSITORY"]
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/actions/runs/{run_id}",
        headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    if (data["conclusion"] != "success" or data["event"] != "workflow_dispatch"
            or data["head_branch"] != "main" or data["head_sha"] != os.environ["GITHUB_SHA"]
            or data["path"] != ".github/workflows/plan.yml"):
        raise ValueError("Run must be a successful manual plan for current main")
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/git/ref/heads/main",
        headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        head = json.load(response)["object"]["sha"]
    if head != os.environ["GITHUB_SHA"]:
        raise ValueError("Main moved since this workflow started; generate a new plan")


def apply_plan(run_id, operation):
    require_environment()
    verify_run(run_id)
    s3 = boto3.client("s3")
    bucket = os.environ["ARTIFACT_BUCKET"]
    prefix = f"plans/{run_id}"
    manifest = json.loads(s3.get_object(Bucket=bucket, Key=prefix + "/manifest.json")["Body"].read())
    validate_manifest(manifest, os.environ["GITHUB_SHA"], os.environ["GITHUB_REPOSITORY"], operation)
    for key, env in (("artifact_bucket", "ARTIFACT_BUCKET"), ("state_bucket", "STATE_BUCKET"), ("region", "AWS_REGION"), ("learner_cidr", "LEARNER_CIDR"), ("ami_id", "AMI_ID")):
        if manifest[key] != os.environ[env]:
            raise ValueError("Backend or deployment target changed; re-plan")
    plan = PLAN / "deployment.tfplan"
    s3.download_file(bucket, prefix + "/deployment.tfplan", str(plan))
    if digest(plan) != manifest["plan_sha256"]:
        raise ValueError("Plan checksum mismatch")
    initialize()
    version = json.loads(run("terraform", "version", "-json", capture=True))["terraform_version"]
    if version != manifest["terraform_version"]:
        raise ValueError("Terraform version differs from plan")
    tf("apply", "-input=false", "-lock-timeout=60s", str(plan))
    # Terraform itself rejects a saved plan if backend state changed after planning.
    if operation == "deploy":
        outputs = json.loads(tf("output", "-json", capture=True))
        from deploy_ec2 import deploy
        deploy(outputs, bucket, manifest["sha"], manifest["app_sha256"])
    else:
        remaining = tf("state", "list", capture=True).strip()
        if remaining:
            raise ValueError("Teardown left state entries; inspect before declaring cleanup complete")


if __name__ == "__main__":
    if sys.argv[1] == "plan":
        if sys.argv[2] not in {"deploy", "destroy"}:
            raise ValueError("Operation must be deploy or destroy")
        make_plan(sys.argv[2])
    elif sys.argv[1] == "apply":
        apply_plan(sys.argv[2], sys.argv[3])
    else:
        raise ValueError("Expected plan or apply")
