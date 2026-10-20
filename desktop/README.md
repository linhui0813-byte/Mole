# Mole Dashboard

An independent, native SwiftUI dashboard for macOS 14 or later, with live
status, disk exploration, and selected-item Trash actions powered by this
repository. This is a separate local app, inspired by the
provided status-screen reference. It is not the commercial Mole Mac app.

```bash
./desktop/build.sh
open "desktop/build/Mole Dashboard.app"
```

Requires Xcode command-line tools, Python 3, and the Go version specified by
the repository. Build output is ignored by Git. The app is signed locally
with an ad hoc signature; it is not notarized for public distribution.

The dashboard shows live CPU, memory, disk, network and process readings,
the collector's health score, hardware details, and any available GPU,
temperature or fan readings. It uses a warm collector every two seconds;
slow enrichment refreshes every 30 seconds, and static hardware descriptions
are cached for ten minutes. A dash means unavailable,
never a simulated reading. The thermal-state badge comes from macOS and is
separate from CPU/GPU temperature. Thermal and GPU fields can be cached between
hardware refreshes.

The process table supports search by name or PID, sorting by CPU, resident
memory or name, selection and an inspection panel. Rows represent individual
processes, including app helpers. They are not aggregated app totals. Process
CPU may exceed 100% because 100% represents one CPU core. `ps` CPU is the
operating system's process accounting value, not a new two-second delta.

The Mole icon stays in the menu bar while the app runs. Closing the dashboard
window keeps readings running; choose **Show Dashboard** from that icon to reopen
it. The menu also shows collection status and CPU/memory readings, with
**Pause readings**, **Resume readings**, **Reconnect collector**, and
**Quit Mole Dashboard**. Reopening a paused dashboard preserves the pause.
Pause stops collection; Resume and Reconnect start a fresh collector. Quit
stops the app and its helper; the helper also exits if its parent disappears.
There is no login item, launch agent, network server, telemetry,
process termination, or fan control. Clean and Analyze are explicit user actions
described below. Subprocesses use fixed arguments and never request administrator access.

## Analyze

Choose **Analyze**, then **Scan folder**, or use **Choose folder…**, **Home**,
**User Library**, or **Applications**. The first page waits for an explicit scan.
The space map assigns area in proportion to measured bytes. Click a folder in
the map or list to scan inside it; the parent button and breadcrumbs navigate
back out. Direct items support name/path filtering and size/name sorting.
Files and each row's reveal button show the item in Finder without opening it.
The **Large files** view shows the engine's discovery list, up to 20 files of at
least 1 MiB; upstream filters omit some file types and files in folded folders.
It is not a complete inventory of every large file.

Measurements reuse the pinned upstream analyzer traversal, hardlink handling, concurrency
budgets, directory filters, and JSON coverage states. The dashboard adapter
runs a fresh scan on each navigation, bypasses saved measurements, and denies
cache publication, so inspecting a folder does not create, replace, prune, or
remove the CLI's scan caches. Symbolic links are measured as links and are not
followed by traversal; selecting an explicit folder path can resolve a link.
Measured size is an estimate within Mole's filters, not an atomic filesystem
snapshot, a whole-volume accounting total, or reclaimable space.

Partial measurements remain marked as lower bounds. Unavailable sizes show
**Unavailable** and receive no map area. Empty folders remain valid zero-size
results. The map groups items after the largest 24; all direct items remain in
the list. A scan reports checked-file/folder counts, has a two-minute budget,
and supports **Stop**. Cancellation and timeouts discard the unfinished result;
choose a smaller folder to retry. Navigation stays disabled until the helper
has stopped, and result identity is bound to the requested path. Closing the
window leaves an explicitly started scan running; quitting cancels it. The
helper also cancels on stdin closure or loss of its parent, with a bounded exit.
There are no administrator requests or new background services.

### Move selected items to Trash

Check individual rows in either list, or use a map tile's context menu. **Select
visible (up to 200)** follows the current filter and sort order. Selections span
both list views; navigation or a new scan clears them. Choose **Review selected
for Trash…** to check up to 200 exact paths. No item moves during review.

The review sheet lists accepted paths, freshly measured allocated-size estimates,
and refused paths with reasons. These estimates can differ from the map and do
not promise reclaimed space. Uncheck any accepted item you want to retain, then
choose **Move checked items to Trash**. Moving a folder includes its contents;
an accepted selected parent covers selected children without counting them twice.
Cancel discards the plan. Zero checked items disables execution.

Review binds each selection to its file version and physical parent. The private
helper accepts only opaque IDs from that review, expires plans after 15 minutes,
and consumes a plan on its first execution attempt. It checks identities,
whitelists, protected contents, and upstream live-cache/database rules again
before each move and at the final Trash guard. A changed object, incomplete
size, inaccessible tree, unknown required visibility, or exceeded budget keeps
the item. Reviews have a two-minute total budget, a 20-second per-item subprocess
budget, and physical tree checks capped at 10,000 entries and eight seconds.
Choose a smaller item if review refuses a large folder.

The desktop policy supplements upstream Analyze's protected-root rules. It keeps
application bundles, Git metadata, recognized credential/session locations,
cloud-document roots, broad application-state collection roots, symbolic links
and redirected user ancestors, sockets and special files, compiled-model state,
Deno stores, and the protected authentication cache and its file aliases. Folder
checks inspect descendants rather than relying on the scan's filtered totals.
This recognizes known sensitive state; it does not classify every personal file
or prove that arbitrary applications have stopped using a selected document.
Review the exact paths yourself. Checks are point-in-time observations, not a
filesystem transaction or a lock on folder contents.

All moves use upstream `mole_delete` in Trash mode and the bundled macOS Trash
transport. Native failure never falls back to permanent deletion, an authorization
prompt, or a second move attempt. **Stop** prevents later moves; an interrupted
or uncertain move remains **unverified** and stops the batch. Check its original
path and Trash before retrying. The result sheet distinguishes moved, kept,
unverified, and unprocessed items. The map refreshes after an execution attempt,
and **Last results** retains its outcomes until another scan or review. Successful
moves and execution refusals use Mole's operation log under
`~/Library/Logs/mole/operations.log`. Trash still occupies disk space until you
empty it in Finder; this app never empties it.

The Go build overlay retains the upstream main file's helper definitions while
renaming its unused CLI entrypoint and supplying the desktop entrypoint from
`desktop/analyzer/`. No original source file is modified. The upstream-isolation
guard covers both analyzer and collector sources, including ignored extra Go
files that could otherwise enter a build.

## Clean

Choose **Clean**, then **Scan**. Review exact paths and scan-estimated sizes,
select individual items or categories, and choose **Move selected to Trash…**.
A confirmation shows the selected count and size before execution. Nothing is
selected automatically. Files in Trash still occupy disk space until the user
empties Trash in Finder. Clean never empties it or falls back to permanent deletion.

This first version covers the existing upstream user-cache and log targets:
immediate children of `~/Library/Caches`, `~/Library/Logs` (keeping the report
directory and Mole history), and the contents of the two user diagnostic-report
directories. It excludes system/admin cleanup, app leftovers, sandbox/group
containers, browser profiles, developer/package-manager stores, snapshots,
recent-item preferences, mail attachments, downloads, and external volumes.
It does not claim full Clean parity with the commercial Mac app or CLI.
The exact `~/Library/Caches/aws_credentials_cache.json` authentication-cache
path and aliases of that file are kept in preview and execution, including
the final Trash boundary. The adapter never reads its credential values.

The native adapter keeps an opaque, private plan in its helper process. Only
IDs from that scan can be executed; plans expire after 15 minutes and are
consumed by one execution attempt. Paths, parent identities, target identities,
whitelists, Deno roots, and protection policy are checked again for each selected
item. The upstream target-specific live-owner and SQLite probes remain in preview
and at the final Trash guard; unknown required evidence keeps that target. A scoped
adapter extends that guard with Deno and parent checks. All moves use upstream `mole_delete`
with Trash mode. The bundled native `trash` transport uses the macOS Trash API;
it adds no deletion policy or permanent fallback. Outcomes retain moved, kept,
unverified, and unprocessed items separately. Successful moves and refusals use
Mole's operation log. An uncertain move stops later items.

Unknown required visibility, inaccessible paths, symlinks, incomplete sizes, and
known active caches/databases are kept. Ordinary disposable logs use upstream's
existing policy without imposing an unrelated administrator-visibility gate.
A scan has four bounded workers, a two-minute budget, and a 1,000-entry cap;
partial results retain only completed item checks and are labeled. A cancelled
scan cannot authorize cleaning. Stop cancels
the current subprocess and prevents later moves. If stopping interrupts a move,
the app marks its outcome unverified. Check the original path and Trash before
trying again. Dashboard verification does not clean existing user files; action tests
use a temporary HOME, mocked process visibility, and a fixture Trash directory.

The build packages an unmodified snapshot of `bin/clean.sh` and `lib/` from the
upstream pin, plus our adapter. These generated resources use hidden directories
so upstream repository checks do not rescan bundled shell copies under an app
path containing spaces. The engine source remains maintained only upstream.

The app icon, header, and About panel reuse the original Mole mascot from
`docs/img/mole-banner.png`; the menu bar uses its monochrome silhouette so macOS
can tint it for the current menu bar appearance. `desktop/Tools/BuildIcons.swift`
extracts that artwork and generates the icons during the build, without changing
the upstream image or adding an image dependency. The source remains credited
to Tw93 and contributors under the repository's GPL-3.0 license.

The desktop build uses a Go build overlay to substitute its own collector
entrypoint for `cmd/status/main.go`. All metric collection and parsing code is
compiled from the current repository without editing the CLI. The adapter
retains the validated full process sample for the desktop table, preserving
the CLI's original JSON contract.

Mole and this derivative dashboard use the repository's GPL-3.0 license.
The app includes the original license, the upstream core commit, and the
dashboard checkout commit it was built from.
The additional dashboard source lives in this directory.

## Core and dashboard ownership

The execution and metric-collection code comes from **Mole CLI (macOS)** at
`tw93/Mole`. Our code lives entirely in `desktop/`, including any compatibility
adapter needed by the graphical dashboard. The sole root-file exception is the
marked dashboard delivery policy appended to `AGENTS.md`; its upstream text
stays unchanged. Keep the other upstream root documentation, CLI entrypoint,
`lib/`, `cmd/`, `internal/`, tests, and dependencies unchanged.

- `main` follows `upstream/main` by fast-forward only.
- `native-dashboard` merges those upstream updates and owns the desktop app.
- `desktop/UPSTREAM_COMMIT` records the exact upstream snapshot in use.
- `desktop/check-upstream.sh` refuses a build if files outside `desktop/` differ
  from that snapshot, except the appended policy above, or extra Go files could
  enter the collector build. Edits to the upstream agent instructions still fail.
- The build compiles the collector from the merged upstream source. It does not
  copy and maintain a second version of the engine.

Upstream updates require a deliberate merge and verification. Changes to
collector interfaces are adapted inside `desktop/`; a merge is not proof that
the dashboard still builds or decodes the live data correctly.

To update from a clean checkout:

```bash
git fetch upstream main
git switch main
git merge --ff-only upstream/main
git switch native-dashboard
git merge --no-commit main
git rev-parse upstream/main > desktop/UPSTREAM_COMMIT
./desktop/check-upstream.sh
./desktop/build.sh
```

Run the dashboard checks below and the repository's required checks before
committing the merge. Adapt only files inside `desktop/` if compatibility work
is needed. Then push `native-dashboard` to `origin`, our GitHub fork. Publishing
an update to the fork's default `main` branch requires separate authorization.
The official `upstream` remote remains the source of core updates.

See [the integration status](UPSTREAM_STATUS.md) for the current source pin,
verification evidence, and known upstream test limitations.

## Automatic dashboard delivery

The appended policy in [AGENTS.md](../AGENTS.md) gives agents standing
authorization to validate, commit, push, and deploy every completed dashboard
update. Stage only the reviewed dashboard and accompanying policy changes,
push `origin/native-dashboard`, then quit the app, rebuild that committed
revision, and reopen the local `desktop/build/Mole Dashboard.app`. Verify the
bundled source commit, signature, and live readings before reporting deployment.
Keep unrelated work intact and report any blocked stage separately.

## Verification

```bash
python3 desktop/Tests/test_upstream_isolation.py
python3 desktop/Tools/analyzer_overlay.py desktop/build/analyzer-tests --test
MOLE_TEST_NO_AUTH=1 go test -race -overlay desktop/build/analyzer-tests/analyzer-overlay.json \
  ./cmd/analyze -run '^TestDashboard' -count=1
python3 desktop/Tests/analyzer_smoke.py
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path desktop/build/cache/swift \
  desktop/Sources/Models.swift desktop/Sources/AnalyzeModels.swift desktop/Sources/CleanStore.swift \
  desktop/Sources/AnalyzeStore.swift desktop/Tests/AnalyzeContract.swift \
  -o desktop/build/analyze-contract
desktop/build/analyze-contract
MOLE_TEST_NO_AUTH=1 go test -race -count=1 ./desktop/pathbinding ./desktop/cleaner
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path desktop/build/cache/swift \
  desktop/Sources/Models.swift desktop/Sources/AnalyzeModels.swift \
  desktop/Sources/CleanStore.swift desktop/Tests/AnalyzeActionsContract.swift \
  -o desktop/build/analyze-actions-contract
desktop/build/analyze-actions-contract
shellcheck --rcfile .shellcheckrc desktop/Engine/clean.sh desktop/Engine/analyze.sh desktop/build.sh
python3 desktop/Tests/check_clean_bundle.py
MOLE_TEST_NO_AUTH=1 go test ./cmd/status
python3 desktop/Tests/collector_smoke.py
xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path desktop/build/cache/swift \
  desktop/Sources/Models.swift desktop/Tests/ModelContract.swift \
  -o desktop/build/model-contract
desktop/build/model-contract desktop/build/live-snapshot.json
```

The smoke check collects three real snapshots within 35 seconds, checks the
complete process table, saves a local ignored fixture, then stops its helper.
The Swift check decodes that real fixture and verifies unavailable readings
stay distinct from zero. Native UI search, sorting, inspection, and pause/resume
were verified on macOS 27.0.1, Apple M5. Menu bar verification covers closing and
reopening the window, preserving Pause across reopening, live collection with
the window closed, Reconnect replacing exactly one helper, and Quit stopping
both processes. The generated app icon includes 1024-pixel artwork, and the
menu template has a transparent background and solid mascot pixels.

Clean tests run the actual adapter and upstream funnel against fixture files:
selected-only recoverable moves, paths with spaces/quotes/Unicode, operation
logging, changed target/parent identities, new whitelist protection, redirected
roots, Deno protection, open/unknown handles, final-sink rechecks, expiry, stale
IDs, duplicate IDs, cancellation, and protocol plan consumption. Native testing
covers scan progress, selection, confirmation cancellation, stopping and rescanning;
it does not clean existing user files.

Analyze checks exercise a fresh scan despite a saved stale-sized measurement,
cache preservation and non-creation, Unicode and quoted paths, symbolic links,
cancellation, inaccessible/missing roots, and a deadline that cancels a folded
`du` probe. Swift contracts cover partial/unavailable presentation, proportional
map area and grouping, request/result binding, invalid responses, cancellation,
and a new scan after stopping. The packaged-helper smoke test uses disposable
files and checks source preservation.

Analyze action tests add selected-only moves and audit records, overlapping parent
selections, credential and special-file refusal, target/parent changes, same-inode
rewrites with restored modification times, late protected-content insertion,
whitelist changes, cancellation after a completed move, native transport failure
without retry, and separation from the Clean protocol. Swift contracts cover
reviewed IDs, refusal reasons, outcome retention, cancelled reviews, and restarting.
Use `-count=1`: the helper built by the Go test harness reads overlay templates
at runtime, so Go's test cache cannot track those template changes.

`python3 desktop/Tests/analyze_actions_smoke.py` is an explicit native-transport
smoke test after building. It creates its own disposable files and temporary HOME,
then moves only its newly created selected file into the real macOS Trash. It
verifies the control file, audit record, and refusal to reuse the consumed plan.
It leaves that fixture in Trash and never empties Trash. Native GUI verification
also used only a named disposable fixture, covering review cancellation, protected
folder refusal, a confirmed move, automatic map refresh, and retained results.
The deployed original application also passed review cancellation and
zero-selection disabling confirmation, with live readings in its status window.
