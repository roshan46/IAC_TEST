import json
import tarfile
import zipfile
from scripts import package


def test_snapshot_is_content_addressed_and_deployable(tmp_path, monkeypatch):
    monkeypatch.setattr(package, "ROOT", tmp_path)
    for name in ("pyproject.toml", "uv.lock", "scripts/smoke.py",
                 "workers/__init__.py", "workers/validate.py", "workers/fulfill.py",
                 "workers/receipt.py", "orderlib/__init__.py", "orderlib/domain.py",
                 "app/__init__.py", "app/templates/orders.html"):
        target = tmp_path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("# fixture\n")
    first = package.build_snapshot()
    original = json.loads((first / "checksums.json").read_text())
    assert first == package.build_snapshot()
    assert original == json.loads((first / "checksums.json").read_text())
    assert json.loads((first / "source.json").read_text())["kind"] == "local-source-snapshot"
    with zipfile.ZipFile(first / "validate.zip") as archive:
        assert "workers/validate.py" in archive.namelist()
        assert "orderlib/domain.py" in archive.namelist()
        assert all((info.external_attr >> 16) & 0o777 == 0o644 for info in archive.infolist())
    with tarfile.open(first / "app.tar.gz") as archive:
        assert "scripts/smoke.py" in archive.getnames()
        assert "app/templates/orders.html" in archive.getnames()
    (tmp_path / "workers/validate.py").write_text("# changed worker\n")
    assert package.build_snapshot() != first
