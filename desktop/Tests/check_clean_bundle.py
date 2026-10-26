#!/usr/bin/env python3
"""Verify that the packaged execution source exactly matches the upstream pin."""
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parents[2]
app = repo / "desktop/build/Mole Dashboard.app/Contents"
pin = (repo / "desktop/UPSTREAM_COMMIT").read_text().strip()
engine = app / "Resources/.MoleEngine"
paths = subprocess.run(
    ["git", "ls-tree", "-rz", "--name-only", pin, "bin/clean.sh", "lib"],
    cwd=repo, check=True, capture_output=True,
).stdout.split(b"\0")
expected = {path.decode() for path in paths if path}
actual = {str(p.relative_to(engine)) for p in engine.rglob("*") if p.is_file()}
assert actual == expected, f"bundled engine file set differs: {actual ^ expected}"
for path in sorted(expected):
    original = subprocess.run(
        ["git", "show", f"{pin}:{path}"], cwd=repo, check=True, capture_output=True,
    ).stdout
    assert (engine / path).read_bytes() == original, f"bundled engine differs: {path}"
assert (app / "Resources/.Clean/clean.sh").read_bytes() == (repo / "desktop/Engine/clean.sh").read_bytes()
assert (app / "Resources/.Analyze/actions.sh").read_bytes() == (repo / "desktop/Engine/analyze.sh").read_bytes()
assert (app / "Resources/.Uninstall/actions.sh").read_bytes() == (repo / "desktop/Engine/uninstall.sh").read_bytes()
for path in [app / "Helpers/mole-dashboard-cleaner", app / "Helpers/TrashTool/trash", app / "Helpers/mole-dashboard-analyzer"]:
    assert path.is_file() and path.stat().st_mode & 0o111, f"missing executable: {path}"
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)
print(f"Dashboard action bundle passed: {len(expected)} exact upstream files, adapter, and signed helpers")
