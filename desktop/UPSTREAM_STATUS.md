# Upstream integration status

Reviewed on 2026-10-20.

- Source: **Mole CLI (macOS)**, `tw93/Mole`, commit
  `7b2a196061e1be7fae4ba422cd9102313fcb321d`.
- Source entry points: the collectors in `cmd/status/`, traversal and JSON
  contracts in `cmd/analyze/`, plus `bin/clean.sh` and its shared protection and
  Trash helpers for the separate Clean adapter.
- Destination: the independent local dashboard in `desktop/`, branch
  `native-dashboard` of `linhui0813-byte/Mole`.
- Synchronization: **Implemented**. All tracked files outside `desktop/` match
  the pinned upstream snapshot except the marked dashboard delivery policy
  appended to `AGENTS.md`. The upstream instructions remain intact, and the
  guard rejects changes to them. Fork-specific code and compatibility work stay
  in `desktop/`.
- This is a source update and a verified local development build, not a release
  of the commercial Mole Mac app or a newly published binary.

## Verification

- Upstream parity guard: passed against the actual checkout.
- Guard contract: the isolated-repository tests passed. Replacing the guard
  with a no-op caused the refusal tests to fail, as expected.
- Native app build and local signature verification: passed.
- Live collector stream and Swift decoding checks: passed.
- Native window: opened with updating readings. The upstream macOS 27 battery
  fix supplies a separate battery-temperature reading without dashboard edits.
- Repository lint, syntax checks, and safety audits: passed. The repository's
  configured fallback used `go vet` because `golangci-lint` is not installed.
- Full repository suite: completed with exit status 1 because the upstream
  source-audit case below failed. Go tests, module loading, integration, and
  installation stages passed. This snapshot must not be described as having
  a fully passing suite.
- Delivery-policy verification: all seven dashboard isolation tests passed,
  including the appended-policy boundary. The full normal-access rerun exited
  1: the unit stage failed on the known audit case and `run_with_timeout: shell
  fallback cleans up watchdog sleep`. The watchdog case passed when rerun alone
  after an earlier sandbox-restricted test run finished. Go tests, module loading,
  integration, and installation passed again; the full rerun remains a failed run.
- Logo and menu bar update: native build, icon resource checks, signature,
  dashboard isolation, and repository checks passed. Native testing verified
  window-close persistence, reopening without resuming a deliberate pause,
  menu Pause/Resume, exactly one collector after Reconnect, and complete cleanup
  on menu Quit. The latest full suite exited 1 only on the known audit case
  below; Go, module loading, integration, and installation stages passed.
- Clean update: selected-item fixture tests (including race detection), native
  build, exact bundled-engine comparison, repository checks, and all Go packages
  passed. Native verification covered a real read-only scan, item/category/all
  selection, zero selection disabling execution, confirmation cancellation,
  stopping, and rescanning. The scan retained a partial flag instead of treating
  unreadable or incomplete checks as zero. Existing user files were not cleaned.
  The final full suite exited 1 only on the known fallback-audit case below;
  Go, module loading, integration, and installation stages passed. An earlier
  run inherited `CARGO_HOME`/`RUSTUP_HOME` from another project and failed four
  unrelated Rust fixture assertions; removing those overrides resolved them.

## User-run log review

The 2026-10-20 user-run log review matched 84 successful Trash moves between
08:39:42 and 08:40:10 across both audit logs, with no recorded failures or
permanent-delete actions. The run exposed an authentication-cache path inside
the generic cache root. The desktop adapter now retains that exact path and
file aliases at preview, execution, and final-sink checks; credential contents
were not inspected. This extra protection is local to the dashboard.
Both authentication-cache regression tests passed with race detection; the
initial test failed against the previous adapter, and disabling the final
check made the late-alias test fail. All Go packages, lint, upstream isolation,
native build, signature, and exact bundled-source checks passed.
The safeguard's full-suite rerun exited 1 only on the existing fallback-audit
case below; Go, module loading, integration, and installation stages passed.

## Known upstream audit failure

`tests/clean_core.bats`, case `engine-absent cleanup fallbacks stay at their
audited count`, expects ten `declare -f safe_clean_guarded` fallback branches;
the pinned upstream source contains eleven.

The same failure was reproduced in a temporary, detached checkout of the
unmodified source commit, with no dashboard files present. That checkout was
removed after the reproduction. The desktop adapter reuses existing protection
and Trash helpers; no upstream code or assertion was changed to silence the failure.

Next check: rerun the case after the next upstream update. Any remediation of
the cleanup implementation or its audited baseline belongs upstream and must
be reviewed there. Keep the execution code identical in this fork.

## Analyze integration

The read-only Analyze page adds a proportional space map, fresh folder scans,
parent/breadcrumb navigation, direct-item filtering and sorting, the upstream
large-file discovery list, and Finder reveal. Partial and unavailable coverage
stay distinct from measured zero. The separate entrypoint uses upstream scan
budgets and filters, bypasses stored results, denies cache publication, and
cancels on Stop, timeout, stdin closure, or parent loss. All implementation and
compatibility code remains in `desktop/`.

- Desktop Go adapter tests passed with race detection, including saved-cache
  bypass, cache preservation/non-creation, symbolic links, partial permissions,
  failed roots, cancellation, and a bounded folded-directory probe.
- Negative checks: allowing cache publication made both read-only cache tests
  fail; the previous isolation guard failed the new analyzer-source case.
- Swift contract checks passed for coverage labels, proportional non-overlapping
  map areas, grouping, path validation, invalid responses, cancellation, late
  responses, edited paths, and restarting after Stop.
- Packaged helper smoke passed against disposable files, including Unicode,
  quoted paths, large-file discovery, missing paths, and source preservation.
- All Go packages, lint/safety checks, seven isolation tests, native build,
  signature, exact Clean bundle, and live collector smoke passed. The linter
  used the configured `go vet` fallback.
- The first full-suite run caught a generated `.go` overlay input being treated
  as an independent package; it now uses `.go.in`. That run also failed the
  known fallback audit and a firmware open-file timing fixture; the latter
  passed alone. The final full-suite rerun exited 1 only on the documented
  fallback-count audit; its Go, module loading, integration, and installation
  stages passed.
- Native interactive verification remains unverified: the control tool returns
  `cgWindowNotFound` for the dashboard window on the external display. A main
  display handoff is pending. Signed-build and helper checks above are verified;
  the previous verified app is preserved for rollback. No window-restoration
  changes or temporary window diagnostics are included in the source.
