#!/usr/bin/env python3
"""Exercise the build boundary in disposable Git repositories, never real core files."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class UpstreamIsolation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mole-desktop-isolation-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "desktop").mkdir()
        (self.root / "cmd/status").mkdir(parents=True)
        (self.root / "cmd/status/metrics.go").write_text("package main\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgSign", "false")
        hooks = self.root / "empty-hooks"
        hooks.mkdir()
        self.git("config", "core.hooksPath", str(hooks))
        self.git("add", "cmd")
        self.git("commit", "-qm", "upstream fixture")
        self.pin = self.git("rev-parse", "HEAD").stdout.strip()
        self.pin_file = self.root / "desktop/UPSTREAM_COMMIT"
        self.pin_file.write_text(self.pin + "\n")
        self.guard = self.root / "desktop/check-upstream.sh"
        shutil.copyfile(Path(__file__).resolve().parents[1] / "check-upstream.sh", self.guard)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, text=True, capture_output=True, check=True)

    def check_guard(self, expected_code=None):
        result = subprocess.run(["/bin/bash", str(self.guard)], cwd=self.root,
                                text=True, capture_output=True, timeout=10)
        if expected_code:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"[{expected_code}]", result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_desktop_and_unrelated_untracked_files_are_allowed(self):
        (self.root / "desktop/view.swift").write_text("// local UI\n")
        (self.root / ".vmark").mkdir()
        (self.root / ".vmark/state.json").write_text("{}")
        self.check_guard()

    def test_changed_core_is_refused_in_worktree_and_index(self):
        (self.root / "cmd/status/metrics.go").write_text("package changed\n")
        self.check_guard("core-diff")
        self.git("add", "cmd")
        self.check_guard("core-diff")

    def test_untracked_and_ignored_go_source_are_refused(self):
        extra = self.root / "cmd/status/local.go"
        extra.write_text("package main\n")
        self.check_guard("untracked-source")
        (self.root / ".git/info/exclude").write_text("local.go\n")
        self.check_guard("untracked-source")

    def test_missing_and_invalid_pin_have_distinct_diagnostics(self):
        self.pin_file.unlink()
        self.check_guard("missing-pin")
        self.pin_file.write_text("not-a-commit\n")
        self.check_guard("invalid-pin")
        self.pin_file.write_text("0" * 40 + "\n")
        self.assertIn("git fetch origin", self.check_guard("missing-commit").stderr)

    def test_source_archive_has_a_clone_diagnostic(self):
        (self.root / ".git").rename(self.root / "saved-git")
        self.assertIn("Clone https://github.com/linhui0813-byte/Mole.git", self.check_guard("not-checkout").stderr)


if __name__ == "__main__":
    unittest.main()
