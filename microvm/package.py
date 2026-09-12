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
sources = {}
if not (root / "lua").is_dir():
    # LuaRocks deploys Lua sources into share/lua, removing its staging lua/.
    # Ask the matching Lua runtime for exactly the modules declared by LCA.
    script = r"""pcall(require, 'luarocks.loader')
local pkg = package
pkg.path = arg[2]..'/?.lua;'..arg[2]..'/?/init.lua;'..pkg.path
assert(loadfile(arg[1]))()
for name, source in pairs(build.modules) do
 if type(source)=='string' and source:match('^lua/') then
  io.write(source, '\t', assert(pkg.searchpath(name, pkg.path), 'missing installed module '..name), '\n')
 end
end

"""
    found = dict(line.split("\t", 1) for line in subprocess.check_output(["lua5.5", "-", str(root / "lca-dev-1.rockspec"), str(root.parents[4] / "share/lua/5.5")], input=script, text=True).splitlines())
    sources = {Path(relative): Path(source) for relative, source in found.items()}
    files += list(sources)

for directory, pattern in [("lua", "*.lua"), ("c", "*.c"), ("bin", "*")]:
    files += [p.relative_to(root) for p in (root / directory).rglob(pattern) if p.is_file()]
files += [Path("scripts") / name for name in ("auth.lua", "login.lua")]
files += [Path("microvm") / name for name in ("bootstrap.lua", "smoke.sh", "worker.lua", "lifecycle.lua", "publish.lua", "headless.lua", "checkpoint.lua")]
files += [p.relative_to(root) for p in (root / "microvm/fixture").iterdir() if p.is_file()]
files += [Path("microvm/Dockerfile")]
revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, text=True, capture_output=True)
assert Path("lua/agent/session.lua") in files, "LCA Lua sources missing from image package"
assert Path("c/crypto.c") in files, "LCA native sources missing from image package"
manifest = {"git_revision": revision.stdout.strip() if revision.returncode == 0 else None, "sha256": {}}
for relative in sorted(files):
    source = sources.get(relative, root / relative)
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
