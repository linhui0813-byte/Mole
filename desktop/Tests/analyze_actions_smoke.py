#!/usr/bin/env python3
"""Exercise packaged review/Trash using only newly created disposable fixture files."""
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import uuid

repo = Path(__file__).resolve().parents[2]
helpers = repo / "desktop/build/Mole Dashboard.app/Contents/Helpers"


class Helper:
    def __init__(self, executable, args, env):
        self.child = subprocess.Popen([str(executable), *args], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True, env=env)
        self.events = queue.Queue()

        def read():
            for line in self.child.stdout:
                self.events.put(json.loads(line))
            self.events.put(None)

        threading.Thread(target=read, daemon=True).start()

    def send(self, value):
        self.child.stdin.write(json.dumps(value) + "\n")
        self.child.stdin.flush()

    def until(self, kind):
        values = []
        while True:
            event = self.events.get(timeout=30)
            assert event is not None, f"helper stopped before {kind}"
            values.append(event)
            if event["kind"] == kind:
                return values

    def close(self):
        self.child.stdin.close()
        try:
            self.child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait(timeout=3)
        self.child.stdout.close()
        self.child.stderr.close()


with tempfile.TemporaryDirectory(prefix="mole-analyze-native-") as temp:
    home = Path(temp)
    folder = home / "Downloads"
    folder.mkdir()
    name = f"mole-dashboard-fixture-{uuid.uuid4().hex}.txt"
    chosen = folder / name
    kept = folder / "unselected-fixture.txt"
    chosen.write_text("Disposable Mole Dashboard Analyze native Trash fixture.\n")
    kept.write_text("This unselected fixture must remain until test teardown.\n")
    env = {**os.environ, "HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
    env.pop("MOLE_TEST_NO_AUTH", None)
    env.pop("MOLE_TEST_TRASH_DIR", None)
    scanner = Helper(helpers / "mole-dashboard-analyzer", [str(folder)], env)
    try:
        frame = scanner.until("done")[-1]
    finally:
        scanner.close()
    service = Helper(helpers / "mole-dashboard-cleaner", ["--analyze-actions"], env)
    try:
        service.send({"action": "review", "request_id": "review", "candidates": [frame["bindings"][str(chosen)], frame["bindings"][str(kept)]]})
        events = service.until("scan_done")
        assert events[-1]["status"] == "ready", events
        items = [event["item"] for event in events if event["kind"] == "item"]
        assert len(items) == 2, events
        selected = next(item["id"] for item in items if item["path"] == str(chosen))
        service.send({"action": "clean", "request_id": "move", "ids": [selected]})
        events = service.until("clean_done")
        results = [event for event in events if event["kind"] == "result"]
        assert len(results) == 1 and results[0]["status"] == "trashed", events
        assert not chosen.exists() and kept.exists()
        assert "unselected fixture" in kept.read_text()
        log = (home / "Library/Logs/mole/operations.log").read_text()
        assert "analyze" in log and name in log and "unselected-fixture.txt" not in log, log
        # Replaying the consumed ID must be refused before any new move.
        service.send({"action": "clean", "request_id": "replay", "ids": [selected]})
        assert service.until("error")[-1]["kind"] == "error"
        assert kept.exists()
    finally:
        service.close()
    # Exercise a collection without its own Git marker and a nested build app.
    project = folder / f"mole-folder-fixture-{uuid.uuid4().hex}"
    (project / "nested-project/.git/objects").mkdir(parents=True)
    (project / "nested-project/.git/HEAD").write_text("ref: refs/heads/disposable-fixture\n")
    (project / "nested-project/.env").write_text("DUMMY_FIXTURE=1\n")
    app = project / "nested-project/.build/Disposable.app/Contents"
    app.mkdir(parents=True)
    (app / "Info.plist").write_text("Disposable build fixture; never launched.\n")
    (app / "outside-link").symlink_to(kept)
    scanner = Helper(helpers / "mole-dashboard-analyzer", [str(folder)], env)
    try:
        frame = scanner.until("done")[-1]
    finally:
        scanner.close()
    service = Helper(helpers / "mole-dashboard-cleaner", ["--analyze-actions"], env)
    try:
        service.send({"action": "review", "request_id": "project-review", "candidates": [frame["bindings"][str(project)]]})
        events = service.until("scan_done")
        projects = [event["item"] for event in events if event["kind"] == "item"]
        assert len(projects) == 1 and projects[0]["category"] == "analyze-folder", events
        project_id = projects[0]["id"]
        service.send({"action": "clean", "request_id": "folder-missing-ack", "ids": [project_id]})
        assert "Acknowledge" in service.until("error")[-1]["message"]
        assert project.exists() and kept.exists()
        # The missing acknowledgement consumed the plan. Obtain fresh IDs.
        service.send({"action": "review", "request_id": "folder-new-review", "candidates": [frame["bindings"][str(project)]]})
        events = service.until("scan_done")
        projects = [event["item"] for event in events if event["kind"] == "item"]
        assert len(projects) == 1 and projects[0]["category"] == "analyze-folder", events
        project_id = projects[0]["id"]
        service.send({"action": "clean", "request_id": "project-move", "ids": [project_id], "acknowledged_items": [project_id]})
        events = service.until("clean_done")
        results = [event for event in events if event["kind"] == "result"]
        assert len(results) == 1 and results[0]["status"] == "trashed", events
        assert not project.exists() and kept.exists()
        assert "unselected fixture" in kept.read_text()
        log = (home / "Library/Logs/mole/operations.log").read_text()
        assert project.name in log and "unselected-fixture.txt" not in log, log
    finally:
        service.close()
    # Library uses a distinct policy class, with the same per-item acknowledgement.
    library = home / "Library/DeveloperFixture"
    sdk = library / f"mole-library-sdk-fixture-{uuid.uuid4().hex}"
    (sdk / "platform-tools").mkdir(parents=True)
    (sdk / "platform-tools/disposable-tool.txt").write_text("Disposable SDK fixture; never executed.\n")
    scanner = Helper(helpers / "mole-dashboard-analyzer", [str(library)], env)
    try:
        frame = scanner.until("done")[-1]
    finally:
        scanner.close()
    service = Helper(helpers / "mole-dashboard-cleaner", ["--analyze-actions"], env)
    try:
        service.send({"action": "review", "request_id": "library-review", "candidates": [frame["bindings"][str(sdk)]]})
        events = service.until("scan_done")
        items = [event["item"] for event in events if event["kind"] == "item"]
        assert len(items) == 1 and items[0]["category"] == "analyze-library-folder", events
        selected = items[0]["id"]
        service.send({"action": "clean", "request_id": "library-missing-ack", "ids": [selected]})
        assert "Acknowledge" in service.until("error")[-1]["message"]
        assert sdk.exists() and kept.exists()
        service.send({"action": "review", "request_id": "library-new-review", "candidates": [frame["bindings"][str(sdk)]]})
        events = service.until("scan_done")
        items = [event["item"] for event in events if event["kind"] == "item"]
        assert len(items) == 1 and items[0]["category"] == "analyze-library-folder", events
        selected = items[0]["id"]
        service.send({"action": "clean", "request_id": "library-move", "ids": [selected], "acknowledged_items": [selected]})
        events = service.until("clean_done")
        results = [event for event in events if event["kind"] == "result"]
        assert len(results) == 1 and results[0]["status"] == "trashed", events
        assert not sdk.exists() and kept.exists()
        assert "unselected fixture" in kept.read_text()
        log = (home / "Library/Logs/mole/operations.log").read_text()
        assert sdk.name in log and "unselected-fixture.txt" not in log, log
    finally:
        service.close()
print("Packaged native Analyze Trash passed: reviewed file, acknowledged collection with build app, and Library SDK fixture moved; missing acknowledgement refused, outside control preserved, audit recorded, replay refused")
print(f"Only newly created fixtures {name}, {project.name}, and {sdk.name} were moved to Trash; Trash was not emptied.")
