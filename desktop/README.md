# Mole Dashboard

An independent, native SwiftUI dashboard for macOS 14 or later, using this
repository's status collectors. This is a separate local app, inspired by the
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
hardware enrichment refreshes every 30 seconds. A dash means unavailable,
never a simulated reading. The thermal-state badge comes from macOS and is
separate from CPU/GPU temperature. Thermal and GPU fields can be cached between
hardware refreshes.

The process table supports search by name or PID, sorting by CPU, resident
memory or name, selection and an inspection panel. Rows represent individual
processes, including app helpers. They are not aggregated app totals. Process
CPU may exceed 100% because 100% represents one CPU core. `ps` CPU is the
operating system's process accounting value, not a new two-second delta.

Pause stops collection. Resume and Reconnect start a fresh collector. Closing
the window quits the app and stops its helper; the helper also exits if its
parent disappears. There is no login item, background service, network server,
telemetry, cleanup, process termination, or fan control. Subprocesses are launched
directly with fixed arguments and no authorization prompts.

The desktop build uses a Go build overlay to substitute its own collector
entrypoint for `cmd/status/main.go`. All metric collection and parsing code is
compiled from the current repository without editing the CLI. The adapter
retains the validated full process sample for the desktop table, preserving
the CLI's original JSON contract.

Mole and this derivative dashboard use the repository's GPL-3.0 license.
The app includes the original license and the source commit it was built from.
The additional dashboard source lives in this directory.

## Verification

```bash
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
stay distinct from zero. Native UI search, sorting, inspection, pause/resume,
and close-window cleanup were also verified on macOS 27.0.1, Apple M5.
