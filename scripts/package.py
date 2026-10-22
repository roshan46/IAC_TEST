"""Build commit-addressed source artifacts; no AWS calls."""
import hashlib
import gzip
import io
import json
from pathlib import Path
import re
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def build(revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Use a full 40-character Git commit SHA")
    target = ROOT / "dist" / revision
    target.mkdir(parents=True, exist_ok=True)
    paths = [ROOT / "pyproject.toml", ROOT / "uv.lock", ROOT / "scripts" / "smoke.py"]
    for directory in ("app", "orderlib", "workers"):
        paths += sorted(p for p in (ROOT / directory).rglob("*")
                        if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc")
    with (target / "app.tar.gz").open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for path in paths:
                    data = path.read_bytes()
                    info = tarfile.TarInfo(path.relative_to(ROOT).as_posix())
                    info.size = len(data)
                    info.mode = 0o644
                    archive.addfile(info, io.BytesIO(data))
    # Each Lambda zip has the same shared code but a different configured handler.
    for name in ("validate", "fulfill", "receipt"):
        with zipfile.ZipFile(target / f"{name}.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for path in paths:
                if path.relative_to(ROOT).parts[0] in {"workers", "orderlib"}:
                    info = zipfile.ZipInfo(path.relative_to(ROOT).as_posix())
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = 0o100644 << 16
                    archive.writestr(info, path.read_bytes())
    manifest = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in target.iterdir() if p.suffix in {".gz", ".zip"}}
    (target / "checksums.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return target


def build_snapshot():
    """Local milestone source ID, explicitly NOT a Git commit."""
    paths = [ROOT / "pyproject.toml", ROOT / "uv.lock", ROOT / "scripts" / "smoke.py"]
    for directory in ("app", "orderlib", "workers"):
        paths += [p for p in (ROOT / directory).rglob("*")
                  if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"]
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0")
        data = path.read_bytes()
        digest.update(str(len(data)).encode() + b"\0" + data)
    target = build(digest.hexdigest()[:40])
    (target / "source.json").write_text(json.dumps({
        "kind": "local-source-snapshot", "sha256": digest.hexdigest()
    }, indent=2) + "\n")
    return target


if __name__ == "__main__":
    print(build_snapshot() if sys.argv[1] == "--snapshot" else build(sys.argv[1]))
