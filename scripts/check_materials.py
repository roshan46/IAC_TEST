"""Check lesson links, Python syntax, YAML, and the supplied workflow asset."""
import ast
import json
from pathlib import Path
import re
import yaml

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {".venv", ".git", ".terraform", "dist", "__pycache__", ".pytest_cache"}


def main():
    counts = {"markdown": 0, "python": 0, "yaml": 0}
    for path in ROOT.rglob("*"):
        if not path.is_file() or EXCLUDED.intersection(path.relative_to(ROOT).parts):
            continue
        if path.suffix == ".md":
            body = path.read_text(encoding="utf-8")
            fences = re.findall(r"(?m)^```.*$", body)
            assert len(fences) % 2 == 0, f"Unclosed fence: {path}"
            for target in re.findall(r"\]\(([^)]+)\)", body):
                if "://" not in target and not target.startswith("#"):
                    assert (path.parent / target.split("#")[0]).exists(), (path, target)
            counts["markdown"] += 1
        elif path.suffix == ".py":
            ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
            counts["python"] += 1
        elif path.suffix in {".yml", ".yaml"}:
            document = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
            if path.parent.name == "workflows":
                assert "on" in document and "jobs" in document, path
            counts["yaml"] += 1
    workflow = json.loads((ROOT / "infra/dev/workflow.asl.json.tftpl").read_text())
    states = workflow["States"]
    assert workflow["StartAt"] in states
    for state in states.values():
        if "Next" in state:
            assert state["Next"] in states
        for catcher in state.get("Catch", []):
            assert catcher["Next"] in states
    permissions = (ROOT / "infra/bootstrap/deployment-permissions.tf").read_text()
    plan_block, apply_block = permissions.split(
        'data "aws_iam_policy_document" "github_apply"', maxsplit=1)
    assert "ec2:RunInstances" not in plan_block
    assert '"s3:GetAccelerateConfiguration"' in plan_block
    assert '"ssm:SendCommand"' in apply_block
    assert '"iam:*"' not in permissions
    assert "application_path" in permissions
    print("PASS:", counts, "and workflow transitions")


if __name__ == "__main__":
    main()
