"""External behavioral/scope checks shared by the two synthetic stress cases."""
import json
from pathlib import Path
import subprocess
import sys


def files(root):
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*")
            if p.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(p.parts)}


def grade(fixture, workspace, trajectory):
    public = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"], cwd=workspace, text=True, capture_output=True, timeout=15)
    contextual = json.loads((fixture / "parser_contract.json").read_text())["parser_contract"] == "path-sensitive-v2"
    hidden_code = '''from analyzer import analyze
calls=[]
def parser(*args):
    calls.append(args)
    return None if args[-1] == "zero" else args
rows=[("pkg/a.py","zero"),("pkg/b.py","zero"),("pkg/a.py","zero"),("pkg/a.py","changed")]
result=analyze(iter(rows),parser)
assert len(result)==4
assert result[0][1] is None and result[1][1] is None and result[2][1] is None
assert len(calls)==EXPECTED
assert result[-1][1]==LAST
'''.replace("EXPECTED", "3" if contextual else "2").replace("LAST", "('pkg/a.py','changed')" if contextual else "('changed',)")
    hidden = subprocess.run([sys.executable, "-c", hidden_code], cwd=workspace, text=True, capture_output=True, timeout=15)
    before, after = files(fixture), files(workspace)
    changed = [name for name in before if before[name] != after.get(name)]
    added = sorted(set(after) - set(before))
    verified = any(e.get("name") == "run" and not (e.get("result") or {}).get("is_error", True)
                   and "unittest" in str(e.get("args", {}).get("command", ""))
                   and "Ran 3 tests" in (e.get("result") or {}).get("content", "")
                   and "OK" in (e.get("result") or {}).get("content", "") for e in trajectory.get("events", []))
    gates = {"public_tests": public.returncode == 0, "hidden_contract": hidden.returncode == 0,
             "scope": changed == ["analyzer.py"] and not added, "verification": verified}
    return {"passed": all(gates.values()), "score": sum(gates.values()) * 25, "hard_gates": gates,
            "evidence": {"changed_files": changed, "added_files": added, "public_output": public.stdout + public.stderr,
                         "hidden_output": hidden.stdout + hidden.stderr}}


def main(fixture):
    print(json.dumps(grade(fixture, Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()))))
