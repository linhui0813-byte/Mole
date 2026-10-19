#!/bin/bash
# Refuse a dashboard build if the reused upstream source has been changed.
set -euo pipefail

DESKTOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/.." && pwd -P)"
PIN_FILE="$DESKTOP_DIR/UPSTREAM_COMMIT"

if ! checkout_root="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2> /dev/null)" || [[ "$checkout_root" != "$REPO_DIR" ]]; then
    printf '%s\n' '[not-checkout] The dashboard source is not at the root of its Git checkout.' >&2
    printf '%s\n' 'Clone https://github.com/linhui0813-byte/Mole.git, switch to native-dashboard, then rebuild there.' >&2
    exit 1
fi
if [[ ! -r "$PIN_FILE" ]]; then
    printf '%s\n' '[missing-pin] desktop/UPSTREAM_COMMIT is missing or unreadable.' >&2
    printf '%s\n' 'Restore desktop/UPSTREAM_COMMIT from Git, then rebuild.' >&2
    exit 1
fi
upstream_commit="$(cat "$PIN_FILE")"
if [[ ${#upstream_commit} -ne 40 || "$upstream_commit" == *[!0-9a-f]* ]]; then
    printf '%s\n' '[invalid-pin] The upstream pin must be one full lowercase Git commit ID.' >&2
    printf '%s\n' 'Record the reviewed upstream commit in desktop/UPSTREAM_COMMIT, then rebuild.' >&2
    exit 1
fi
if ! git -C "$REPO_DIR" cat-file -e "$upstream_commit^{commit}" 2> /dev/null; then
    printf '%s\n' '[missing-commit] The pinned upstream commit is unavailable in this checkout.' >&2
    printf 'Run: git fetch origin %s\n' "$upstream_commit" >&2
    exit 1
fi

if git -C "$REPO_DIR" diff --no-ext-diff --no-textconv --quiet "$upstream_commit" -- . ':(exclude)desktop/' ':(exclude)AGENTS.md'; then
    :
else
    comparison_status=$?
    if [[ "$comparison_status" -eq 1 ]]; then
        printf '%s\n' '[core-diff] Files outside desktop/ differ from the pinned upstream source.' >&2
        printf "Inspect: git diff %s -- . ':(exclude)desktop/'\n" "$upstream_commit" >&2
        printf '%s\n' 'Keep fork-specific changes in desktop/, or finish the upstream merge and update its pin.' >&2
    else
        printf '%s\n' '[git-error] Git could not compare the checkout with the upstream source.' >&2
        printf '%s\n' 'Run git status, resolve the Git error, then retry desktop/check-upstream.sh.' >&2
    fi
    exit 1
fi

# Only an appended, marked fork policy may differ in the upstream agent guide.
python3 - "$REPO_DIR" "$upstream_commit" << 'PY'
from pathlib import Path
import subprocess
import sys

root, pin = sys.argv[1:]
try:
    baseline = subprocess.run(["git", "-C", root, "show", f"{pin}:AGENTS.md"],
                              check=True, capture_output=True).stdout
    path = Path(root) / "AGENTS.md"
    current = path.read_bytes() if not path.is_symlink() else b""
except (OSError, subprocess.CalledProcessError):
    current, baseline = None, b""
start = b"\n<!-- mole-dashboard-fork:start -->\n"
end = b"<!-- mole-dashboard-fork:end -->\n"
valid = current == baseline
if current is not None and current.count(start) == 1 and current.count(end) == 1:
    original, policy = current.split(start)
    valid = original == baseline and policy.endswith(end)
if not valid:
    print("[agent-policy-diff] AGENTS.md differs beyond its appended dashboard policy.", file=sys.stderr)
    print("Restore the upstream text; keep fork rules in one marked section at the end.", file=sys.stderr)
    sys.exit(1)
PY

# Untracked Go files can be compiled even when Git ignores them. Include those
# files in this check, while leaving unrelated files such as .vmark/ alone.
if ! extra_sources="$(git -C "$REPO_DIR" ls-files --others -- \
    ':(glob)cmd/status/*.go' ':(glob)internal/**/*.go')"; then
    printf '%s\n' '[git-error] Git could not inspect untracked collector source.' >&2
    printf '%s\n' 'Run git status, resolve the Git error, then retry desktop/check-upstream.sh.' >&2
    exit 1
fi
if [[ -n "$extra_sources" ]]; then
    printf '%s\n' '[untracked-source] Extra Go source exists in the upstream collector or internal packages.' >&2
    printf '%s\n' "$extra_sources" >&2
    printf '%s\n' 'Move fork-specific source into desktop/, then retry the build.' >&2
    exit 1
fi
printf 'Upstream core matches %s; only desktop/ and the appended dashboard policy may differ.\n' "$upstream_commit"
