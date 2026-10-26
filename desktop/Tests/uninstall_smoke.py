#!/usr/bin/env python3
"""Packaged uninstall: move only a newly created disposable app into native Trash."""
import json
import os
from pathlib import Path
import plistlib
import queue
import subprocess
import tempfile
import threading
import uuid

repo = Path(__file__).resolve().parents[2]
helper = repo / "desktop/build/Mole Dashboard.app/Contents/Helpers/mole-dashboard-cleaner"

with tempfile.TemporaryDirectory(prefix="mole-uninstall-native-") as temp:
    home = Path(temp).resolve()
    name = "MoleUninstallFixture-" + uuid.uuid4().hex
    app = home / "Applications" / (name + ".app")
    (app / "Contents/MacOS").mkdir(parents=True)
    bundle_id = "com.molefixture." + uuid.uuid4().hex
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id, "CFBundleExecutable": name,
        "CFBundleName": name, "CFBundleShortVersionString": "1.0",
    }))
    (app / "Contents/MacOS" / name).write_text("Disposable uninstall fixture.\n")
    preferences = home / "Library/Preferences" / (bundle_id + ".plist")
    preferences.parent.mkdir(parents=True)
    preferences.write_text("Unchecked fixture settings must remain.\n")
    control = home / "unselected-control.txt"
    control.write_text("Keep this unselected fixture.\n")
    identity = (app.stat().st_dev, app.stat().st_ino)
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
    child = subprocess.Popen([str(helper), "--uninstall"], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    events = queue.Queue()

    def read():
        for line in child.stdout:
            events.put(json.loads(line))
        events.put(None)

    threading.Thread(target=read, daemon=True).start()

    def request(value, final):
        child.stdin.write(json.dumps(value) + "\n")
        child.stdin.flush()
        result = []
        while True:
            event = events.get(timeout=150)
            assert event is not None, f"helper stopped before {final}"
            result.append(event)
            if event["kind"] == final:
                return result

    try:
        inventory = request({"action": "apps", "request_id": "inventory"}, "scan_done")
        app_row = next(event["app"] for event in inventory if event["kind"] == "app" and event["app"]["path"] == str(app))
        review = request({"action": "app_review", "request_id": "review", "app_id": app_row["id"]}, "scan_done")
        bundle = next((event["item"] for event in review if event["kind"] == "item" and event["item"]["category"] == "uninstall-bundle"), None)
        assert bundle is not None, review
        assert app.exists() and preferences.exists() and control.exists(), "Review mutated a fixture"
        result = request({"action": "clean", "request_id": "uninstall", "ids": [bundle["id"]]}, "clean_done")
        assert any(event["kind"] == "result" and event["status"] == "trashed" for event in result), result
        assert not app.exists() and preferences.exists() and control.exists(), result
        trash_app = Path.home() / ".Trash" / app.name
        # HOME is isolated for the helper; Foundation resolves the real account's Trash.
        assert trash_app.is_dir(), f"Native Trash fixture missing: {trash_app}"
        assert (trash_app.stat().st_dev, trash_app.stat().st_ino) == identity, "Trash object changed"
        log = (home / "Library/Logs/mole/operations.log").read_text()
        assert "uninstall" in log and str(app) in log and "TRASHED" in log, log
        replay = request({"action": "clean", "request_id": "replay", "ids": [bundle["id"]]}, "error")
        assert "expired" in replay[-1]["message"], replay
        print("Packaged uninstall passed: native Trash identity, unchecked data/control preservation, audit, one-use plan")
        print(f"Disposable fixture retained in Trash: {trash_app}")
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=3)
        child.stdout.close()
        child.stderr.close()
