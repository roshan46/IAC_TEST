from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import pipeline
from pipeline import validate_manifest
from package import build


def test_initialize_passes_backend_values_as_separate_arguments(monkeypatch):
    calls = []
    monkeypatch.setenv("STATE_BUCKET", "state-bucket")
    monkeypatch.setenv("AWS_REGION", "us-east-2")
    monkeypatch.setattr(pipeline, "tf", lambda *args, **kwargs: calls.append(args))
    monkeypatch.setattr(pipeline, "run", lambda *args, **kwargs: "tracked.lock\n")

    pipeline.initialize()

    args = calls[0]
    assert ("-backend-config", "bucket=state-bucket") == args[2:4]
    assert not any(arg.startswith("-backend-config=") for arg in args)


def test_plan_freshness_and_identity():
    now = datetime.now(timezone.utc)
    manifest = {"sha": "a" * 40, "repository": "owner/repo",
                "operation": "deploy", "created_at": now.isoformat()}
    validate_manifest(manifest, "a" * 40, "owner/repo", "deploy", now)
    with pytest.raises(ValueError):
        validate_manifest(manifest, "b" * 40, "owner/repo", "deploy", now)
    with pytest.raises(ValueError):
        validate_manifest(manifest, "a" * 40, "owner/repo", "destroy", now)
    with pytest.raises(ValueError):
        validate_manifest(manifest, "a" * 40, "owner/repo", "deploy", now + timedelta(hours=25))


def test_package_rejects_untrusted_revision():
    with pytest.raises(ValueError):
        build("../other-directory")
