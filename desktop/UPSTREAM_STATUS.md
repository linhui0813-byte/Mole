# Upstream integration status

Reviewed on 2026-10-20.

- Source: **Mole CLI (macOS)**, `tw93/Mole`, commit
  `7b2a196061e1be7fae4ba422cd9102313fcb321d`.
- Source entry points: the collectors in `cmd/status/`, traversal and JSON
  contracts in `cmd/analyze/`, plus `bin/clean.sh` and its shared protection and
  Trash helpers for the separate Clean and Analyze action adapters.
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
- Hui verified the read-only explorer in the native window. Earlier automation
  could not attach to the original window on the external display. After the
  committed application was rebuilt and reopened in the foreground, native
  control succeeded with live readings. No window-restoration changes or
  temporary window diagnostics are included in the source.

## Analyze selected-item actions

Implemented entirely inside `desktop/`. Scanning remains read-only; selected
paths can now enter a separate review and explicit Trash execution. The shared
private plan service preserves the original Clean scope and rejects Analyze
review requests in Clean mode. Review captures fresh sizes, omits overlapping
children, reports refused paths, and binds accepted items to their file version
and physical parent. Only reviewed IDs can execute, once, within 15 minutes.

The action adapter checks the upstream Analyze root policy and the unmodified
cleanup safety helpers. It adds bounded physical descendant checks for protected
state, recognized credentials, application bundles, Git metadata, symlinks, and
special files. The final guard repeats the binding, parent, whitelist and live
checks before the existing `mole_delete` funnel. Production uses one native Trash
attempt without Finder authorization, retry, or permanent fallback. Unknown
outcomes stop later moves. These are point-in-time checks; folder contents are
not transactionally locked, and user review of selected documents remains required.

- Go action and binding tests passed with race detection and fresh runs. Fixtures
  cover exact selected-only moves and logs, parent/child overlap, object replacement,
  same-inode rewrites with restored mtime, parent replacement, credential/symlink/
  special-file refusal, late protected descendants, new whitelists, cancellation,
  failed native transport without retry, and Clean/Analyze protocol separation.
- Negative checks passed: weakening recognized-credential protection and ignoring
  the stronger object-version stamp each made its regression fail at the intended
  assertion. Read-only scanner/cache and isolation regressions remain covered.
- Swift contracts passed for accepted IDs, refused paths, result retention,
  cancellation with a late ready response, restart, and plan reset. Existing
  Analyze presentation and scan contracts also passed.
- Packaged native smoke used only newly created disposable files: one selected
  file moved to macOS Trash, the unselected control remained, the temporary-HOME
  audit record matched, and reusing the consumed plan was refused.
- Native GUI testing used a disposable folder in an independently identified QA
  copy. Review accepted the ordinary file and kept a folder containing a dummy
  `.env`; cancelling left both intact. After Hui approved the exact test file,
  confirmation moved it to Trash, all controls/protected files remained, the map
  refreshed from five items to four, and **Last results** remained available.
- The deployed original application also passed native review checks: exact
  accepted paths, the offending protected descendant named in its refusal,
  zero checked items disabling confirmation, and cancellation preserving all
  controls. Its live status window was verified after foreground reopening.
- The full suite completed with exit status 1 only on the already reproduced
  upstream fallback-count audit documented above. Go, module loading, integration, and
  installation stages passed. Core source and the failing assertion remain unchanged.

The prior verified application is preserved locally for rollback. Delivery is a
commit on the fork's `native-dashboard` branch and a locally signed development
app, not a public binary release.

## Review refusal follow-up

The reported generic folder-budget refusal combined the entry cap and deadline,
masking a Chromium profile behind a large cache traversal. The all-kept review
also showed zero selected bytes and continued to invite selection despite having
no eligible items.

The desktop policy now recognizes exact Chromium profile metadata before walking
its cache, without reading credential values. It keeps profile roots and known
private-data files, repeats that check at the final Trash boundary, and distinguishes
entry-count limits from time limits. Existing limits remain unchanged. The sheet
shows **Nothing eligible**, a factual all-kept summary, **Reveal in Finder**, and
**Done** when nothing is eligible. Disabled confirmation text stays readable when
an otherwise eligible review has zero checked items.

Regression tests failed on the previous implementation at the intended assertions:
the large profile returned the generic limit reason, and an all-kept review still
invited a move. Fixtures also cover metadata-only cookie detection, distinct limits,
and browser data appearing during final sizing. The reported user folder is used
only for read-only metadata and refusal verification; no move is attempted.

Fresh Go race tests and Swift action contracts passed. The metadata check on the
reported folder returned the browser-profile refusal in 0.42 seconds. Native QA
with a dummy profile verified **Nothing eligible**, the specific refusal reason,
**Reveal in Finder**, **Done**, and no execution button. All dummy files and the
unselected control remained unchanged. The full suite completed with exit status 1
only on the documented upstream fallback-count audit; its Go, module-loading,
integration, and installation stages passed.

## Whole-project Analyze review, 2026-10-20

The dashboard's blanket `.git` refusal conflated automatic cleanup with an
explicit move of a selected checkout. The reported project also had about
171,000 entries, internal links, project-local settings, and dependency SQLite
test fixtures. Simply deleting that refusal would hit the ordinary entry cap
and then the automated cleanup requirement for administrator process visibility.

The desktop adapter now offers a separate, acknowledged whole-project review for
owned checkouts under HOME, outside Library and hidden home roots. It physically
walks metadata without following internal links, includes Git history and local
settings, and retains root protection, whitelists, application/profile/credential
root exclusions, Git locks, mount checks, exact object/parent bindings, one-use
plans, and the upstream Trash/logging funnel. It never executes Git config or hooks.
The helper requires the acknowledgement for each opaque project ID; the UI
requires saving work and closing project tools before enabling confirmation.

This explicit user-data action checks SQLite families within the invoking account.
Open handles, diagnostic output, unexpected statuses, timeouts, and interrupted
probes do not authorize a move. It does not certify administrator-wide inactivity;
automatic Clean and ordinary Analyze retain their existing visibility contract.
This scope is deliberate, rather than treating a missing administrator view as
evidence that a database is idle. Real access errors name their path and the
Finder/System Settings access checks the user can make.

Regression fixtures cover over 10,000 entries, included Git/.env data, preserved
links and outside controls, account-scoped idle/open/unknown database states,
late whitelist patterns and final-sizing insertion, Git locks, inaccessible
subfolders, missing acknowledgement, plan consumption, and a fresh acknowledged
execution. Go race tests and Swift contracts pass. The required full suite
retains its one documented upstream fallback-count failure; repository checks
and upstream isolation pass.

Read-only review of the reported project completed in 4.46 seconds and produced
an `analyze-project` item. Native verification displayed its whole-project warning,
unchecked acknowledgement, and disabled Trash button. Cancelling preserved the
project. No execution command was sent for it. Delivery rebuilds the committed
revision and refreshes the separately requested `/Applications` installation.
The packaged native Trash smoke also passed for a newly created file and an
acknowledged project folder, preserving the outside control and audit records.
Only those disposable fixtures entered Trash; Trash was not emptied.

## General whole-folder Analyze review, 2026-10-20

The previous fix recognized selected Git roots only and still rejected a parent
collection containing a nested build app. The reported `xiaolai` folder contains
several repositories, including `XiaolaiDict/.build/HuiDict.app`; it is a user-data
folder rather than an app-uninstall target. The new collection regression was
observed failing before the fix and passes after it.

Owned real user folders now receive the same explicit acknowledgement without
requiring a Git marker. Nested projects, local settings, internal links and whole
build app bundles travel with the reviewed parent. A standalone app or a selected
path inside one still refuses; bundles are never patched or partially removed.
`~/Applications`, hidden home roots, `Library`, HOME/system roots, and the standard
personal collection roots remain outside this action. The existing whitelist,
account-scoped database, browser-profile, credential-root, special-file, mount,
identity and final-sink checks remain in force. Automatic Clean is unchanged.

The private protocol now uses `acknowledged_items` for both project and folder
IDs. Missing acknowledgement consumes the private plan without starting a move;
new review IDs are required. Swift contracts cover both categories and cleared
consent. Fixture tests verify a collection with multiple repositories, local
settings and a nested app moves intact, its link remains a link, and its outside
control stays untouched. Tests also retain standalone credential refusal and
late credential-root insertion at the final guard.

The reported collection passed read-only review in 9.13 seconds. Native UI
verification displayed **Whole folder**, the complete-contents warning, an
unchecked acknowledgement and disabled Trash button; cancelling preserved the
folder. No execution command was sent for user folders. Packaged native Trash
verification used a newly created collection containing a build-app fixture and
verified missing acknowledgement refusal, a fresh acknowledged move, preserved
outside control, audit records and one-use IDs. Trash was not emptied.
Repository checks, upstream isolation, Go race tests and Swift contracts pass.
The full suite finishes with the same documented upstream fallback-count failure;
its Go, module-loading, integration and installation stages pass.

## Large Library-folder review, 2026-10-21

The whole-folder classifier excluded all of `Library`, so the selected Android
SDK fell back to the older 10,000-entry review. A regression with 10,001 files
failed on the previous route before the fix. The dashboard now classifies owned
Library subfolders separately as `analyze-library-folder`, with the same bounded
1,000,000-entry / eight-second metadata walk and an explicit per-item
acknowledgement. This is a general Library routing fix, with no Android-specific
path exception and no upstream execution changes.

Library keeps upstream live-cache and complete-visibility database validation;
it never uses the account-scoped database exception for ordinary user folders.
Protected roots, application-state collection roots, their selected ancestors,
whitelists, credentials, browser profiles, mounted filesystems, special files,
identity binding, final-sink checks, one-use plans, Trash and logging remain
enforced. The warning also names installed tools and SDKs as included contents.
Regressions cover large Library folders, protected roots, unknown database
visibility and a database appearing during final sizing.

The real SDK's read-only review completed in 2.05 seconds and returned an eligible
Library-folder item. Native verification displayed **Whole Library folder**, an
unchecked acknowledgement and disabled Trash button. Cancelling preserved the
SDK's root identity; no execution command was sent for it. Packaged native Trash
verification moved only newly created disposable file, collection/build-app and
Library SDK fixtures, refused missing acknowledgements, preserved the unselected
control and recorded the audit trail. Trash was not emptied.

Fresh Go race tests, analyzer-overlay regressions, Swift action/Analyze contracts,
packaged analyzer and action smoke checks, ShellCheck, repository checks and
upstream isolation pass. The full suite completed with exit status 1 only on the
documented upstream fallback-count assertion; its Go, module-loading, integration
and installation stages passed. Delivery rebuilds the committed revision and
updates the separately requested `/Applications` installation, retaining the
previous verified application for rollback.
