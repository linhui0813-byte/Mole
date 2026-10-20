#!/usr/bin/env python3
"""Check the packaged Analyze protocol against disposable files, never user content."""
import json
from pathlib import Path
import select
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[2]
helper = repo / "desktop/build/Mole Dashboard.app/Contents/Helpers/mole-dashboard-analyzer"


def scan(path):
    child = subprocess.Popen([str(helper), str(path)], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        frames = []
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            readable, _, _ = select.select([child.stdout], [], [], max(0, deadline - time.monotonic()))
            if not readable:
                raise AssertionError("Analyze protocol exceeded fixture time limit")
            line = child.stdout.readline()
            if not line:
                break
            frames.append(json.loads(line))
        child.wait(timeout=3)
        return child.returncode, frames
    finally:
        child.stdin.close()
        if child.poll() is None:
            child.kill()
        child.wait(timeout=3)
        child.stdout.close()
        child.stderr.close()


with tempfile.TemporaryDirectory(prefix="mole-analyze-") as temp:
    root = Path(temp)
    nested = root / "reports ' 分析"
    nested.mkdir()
    large = nested / "large file.bin"
    large.write_bytes(b"a" * 2 * 1024 * 1024)
    (root / "small.txt").write_text("fixture")
    code, frames = scan(root)
    assert code == 0 and frames[-1]["kind"] == "done", frames
    result = frames[-1]["result"]
    assert Path(result["path"]) == root
    assert result["scan_status"] == "complete"
    assert {Path(item["path"]).name for item in result["entries"]} == {nested.name, "small.txt"}
    assert any(Path(item["path"]) == large for item in result["large_files"])
    assert large.read_bytes() == b"a" * 2 * 1024 * 1024
    code, frames = scan(root / "missing")
    assert code != 0 and frames[-1]["kind"] == "error"
    assert all("result" not in frame for frame in frames)
print("Packaged Analyze smoke passed: exact paths, sizes, large files, missing-folder failure, source preservation")
