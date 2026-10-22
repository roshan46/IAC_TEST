from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import sys
import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from pipeline import validate_manifest
from package import build


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
