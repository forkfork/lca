#!/usr/bin/env python3
"""Freeze an allowlisted checkout (including edits), never HOME or Git metadata."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

root = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=False)
files = [Path("lca-dev-1.rockspec")]
for directory, pattern in [("lua", "*.lua"), ("c", "*.c"), ("bin", "*")]:
    files += [p.relative_to(root) for p in (root / directory).rglob(pattern) if p.is_file()]
files += [Path("scripts") / name for name in ("auth.lua", "login.lua")]
files += [Path("microvm") / name for name in ("bootstrap.lua", "smoke.sh")]
files += [p.relative_to(root) for p in (root / "microvm/fixture").iterdir() if p.is_file()]
files += [Path("microvm/Dockerfile")]
manifest = {"git_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(), "sha256": {}}
for relative in sorted(files):
    source = root / relative
    if source.is_symlink():
        raise ValueError(f"Refusing symlink: {relative}")
    target = out / ("Dockerfile" if relative == Path("microvm/Dockerfile") else relative)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    manifest["sha256"][str(relative)] = hashlib.sha256(source.read_bytes()).hexdigest()
(out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
with zipfile.ZipFile(str(out) + ".zip", "x", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(out.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(out))
print(f"Context: {out}\nArtifact: {out}.zip")
