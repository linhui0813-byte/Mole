# Upstream integration status

Reviewed on 2026-10-19.

- Source: **Mole CLI (macOS)**, `tw93/Mole`, commit
  `7b2a196061e1be7fae4ba422cd9102313fcb321d`.
- Source entry point: the collectors in `cmd/status/`.
- Destination: the independent local dashboard in `desktop/`, branch
  `native-dashboard` of `linhui0813-byte/Mole`.
- Synchronization: **Implemented**. All tracked files outside `desktop/` match
  the pinned upstream snapshot. Fork-specific code and compatibility work stay
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

## Known upstream audit failure

`tests/clean_core.bats`, case `engine-absent cleanup fallbacks stay at their
audited count`, expects ten `declare -f safe_clean_guarded` fallback branches;
the pinned upstream source contains eleven.

The same failure was reproduced in a temporary, detached checkout of the
unmodified source commit, with no dashboard files present. That checkout was
removed after the reproduction. The dashboard does not call these cleanup
paths, and no upstream code or assertion was changed to silence the failure.

Next check: rerun the case after the next upstream update. Any remediation of
the cleanup implementation or its audited baseline belongs upstream and must
be reviewed there. Keep the execution code identical in this fork.
