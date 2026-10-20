#!/usr/bin/env python3
"""Keep upstream helpers intact while substituting a read-only desktop entrypoint."""
import json
from pathlib import Path
import sys

repo = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
source = (repo / "cmd/analyze/main.go").read_text()
needle = "func main() {"
if source.count(needle) != 1:
    raise SystemExit("Analyze entrypoint changed upstream; review the desktop adapter before building.")
# Non-Go suffix keeps generated overlay input out of repository-wide ./... builds.
replacement = out / "analyzer-upstream-main.go.in"
replacement.write_text(source.replace(needle, "func upstreamCLIMain() {", 1))
paths = {
    str(repo / "cmd/analyze/main.go"): str(replacement),
    str(repo / "cmd/analyze/dashboard_adapter.go"): str(repo / "desktop/analyzer/main.go.in"),
    str(repo / "cmd/analyze/dashboard_policy.go"): str(repo / "desktop/analyzer/policy.go.in"),
}
if "--test" in sys.argv[2:]:
    paths[str(repo / "cmd/analyze/dashboard_adapter_test.go")] = str(repo / "desktop/analyzer/main_test.go.in")
    paths[str(repo / "cmd/analyze/dashboard_project_test.go")] = str(repo / "desktop/analyzer/project_test.go.in")
(out / "analyzer-overlay.json").write_text(json.dumps({"Replace": paths}))
