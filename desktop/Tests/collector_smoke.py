#!/usr/bin/env python3
"""Bounded integration check of the actual, read-only desktop collector."""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time

root = Path(__file__).resolve().parents[1]
helper = root / "build/Mole Dashboard.app/Contents/Helpers/mole-dashboard-collector"
process = subprocess.Popen(
    [str(helper)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    env={**os.environ, "MOLE_TEST_NO_AUTH": "1", "LC_ALL": "C"},
)
records = queue.Queue()


def read_records():
    for line in process.stdout:
        records.put(line)


threading.Thread(target=read_records, daemon=True).start()
frames = []
deadline = time.monotonic() + 35
try:
    while time.monotonic() < deadline:
        try:
            line = records.get(timeout=min(1, max(0.01, deadline - time.monotonic())))
        except queue.Empty:
            if process.poll() is not None:
                raise AssertionError(f"collector exited early: {process.returncode}")
            continue
        frame = json.loads(line)
        assert 0 <= frame["cpu"]["usage"] <= 100
        assert frame["memory"]["total"] > 0
        assert 0 <= frame["health_score"] <= 100
        frames.append(frame)
        if frame["enriched"] and len(frames) >= 3:
            rows = frame["processes"]
            assert len(rows) > len(frame["top_processes"]), "full process sample missing"
            assert len({p["pid"] for p in rows}) == len(rows)
            assert all(p["pid"] > 0 and p["cpu"] >= 0 for p in rows)
            assert frame["process_stale"] is False
            assert frames[-1]["collected_at"] > frames[0]["collected_at"]
            assert frame["hardware"]["cpu_model"]
            (root / "build/live-snapshot.json").write_text(json.dumps(frame))
            print(json.dumps({"result": "passed", "frames": len(frames),
                              "processes": len(rows), "enriched": True,
                              "partial": bool(frame.get("collection_error"))}))
            break
    else:
        raise AssertionError("no complete, updating collector stream within 35 seconds")
finally:
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    process.stdout.close()
    process.stderr.close()
