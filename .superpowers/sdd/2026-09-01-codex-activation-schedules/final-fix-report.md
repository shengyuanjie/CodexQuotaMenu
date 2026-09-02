# Final fix report — Codex activation schedules

Date: 2026-09-01

Base reviewed head: `cc5feadfa48418ccf94366cc160ff149d6f6b661`.

This report records the final review/fix wave. No real `~/.codex/automations`
file was read, written, moved, or deleted. Tests use temporary automation roots
and isolated `UserDefaults` suites; the GUI harness injects clipboard and URL
open handlers and does not open or send anything to Codex.

## A. Exact ownership and scoped prompt

- **RED:** The reviewed baseline classified ownership from a prefix and allowed
  broad prefix wording in the empty-list prompt.
- **GREEN:** `ManagedAutomationPolicy.managedTime(from:)` is the one exact
  `CodexQuotaMenu · HH:mm` parser. The reader, reconciler, and prompt policy use
  it. Malformed prefix names are diagnostics only and prompt text says they must
  remain untouched. Regression coverage includes `backup`, `06:00 copy`, and
  empty-list scope.
- Files: `ActivationSchedule.swift`, `CodexAutomationReader.swift`,
  `AutomationReconciler.swift`, `SyncPromptBuilder.swift`, matching tests.

## B. Conservative TOML reader

- **RED:** The prior line-oriented reader did not distinguish top-level fields,
  duplicate recognized keys, or table shadowing.
- **GREEN:** `StringFieldMap` accepts only structurally unambiguous top-level
  values, rejects missing/unparseable names, duplicates, recognized table keys,
  malformed files, unsupported versions, and unreadable files as `unavailable`.
  Unknown unambiguous fields/tables are tolerated. A personal top-level name is
  ignored even when a prompt contains the managed prefix.
- Files: `CodexAutomationReader.swift`, `CodexAutomationReaderTests.swift`.

## C. Corrupt preference protection

- **RED:** Non-Data preference values and duplicate stable IDs were not fully
  distinguished/validated; mutation safety after a load error was incomplete.
- **GREEN:** Store uses `object(forKey:)`, validates IDs and times, preserves bad
  values, and all model mutations reject while `loadError` exists. The window
  disables Add, row checkbox/picker/delete, and Sync in that state.
- Files: `ActivationSchedule.swift`, `ActivationScheduleStore.swift`,
  `ActivationScheduleSettingsModel.swift`, window and tests.

## D. Add flow

- **RED:** Adding could not prove first-free-minute selection or full-day
  behavior.
- **GREEN:** The actual Add action scans from the injected current minute,
  wraps across midnight, and reports the localized 1,440-minute-full error
  without changing storage. Deterministic controller tests cover both paths.
- Files: `ActivationScheduleWindowController.swift`, corresponding tests and
  `Localization.swift`.

## E. Timezone correctness

- **RED:** Missing `TZID` could be accepted and the settings model kept a
  startup-time timezone value.
- **GREEN:** RRULE keys are case-insensitive; a matching explicit `TZID` is
  mandatory. A provider supplies the current IANA identifier independently for
  each refresh, mutation reconciliation, and prompt. Tests cover missing,
  lowercase, mismatch, and provider-change cases.
- Files: `AutomationReconciler.swift`, `ActivationScheduleSettingsModel.swift`,
  matching tests.

## F. Background scanning

- **RED:** Automation scanning could execute synchronously on the main actor
  and stale scans could overwrite newer state.
- **GREEN:** Reader work runs in a utility detached task. Main-actor results
  have a monotonically increasing generation gate. Startup establishes the
  existing refresh/timers before scheduling the scan; open/focus avoids a
  duplicate immediate scan. Delayed-reader tests prove prompt return and stale
  result suppression.
- Files: `ActivationScheduleSettingsModel.swift`,
  `ActivationScheduleWindowController.swift`, `AppDelegate.swift`, tests.

## G. GUI and feedback

- **RED:** Stale feedback could survive reopening/refresh; completion guidance
  was ambiguous.
- **GREEN:** Reopen/manual refresh clears visible feedback while preserving the
  retry prompt. Localized success says to paste and send once; open failure says
  to open Codex manually. Window tests use injected handlers and never open
  Codex.
- Files: `ActivationScheduleWindowController.swift`, `Localization.swift`,
  `ActivationScheduleWindowControllerTests.swift`, `LocalizationTests.swift`.

## H. Documentation

- **RED:** Ownership wording was prefix-based and privacy/product docs omitted
  some stored activation fields.
- **GREEN:** Chinese/English README, product guides, privacy notices, plan, and
  design spec describe exact-format ownership, local IDs/hour/minute/enabled
  values, read-only checks versus real synchronization, and silent successful
  scheduled runs. Privacy dates are 2026-09-01.
- Files: `README*`, `PRIVACY*`, `docs/product-and-usage*`, spec, and plan.

## I. Verification and deferred coverage

Fresh GREEN commands (Xcode at `/Applications/Xcode.app/Contents/Developer`,
with `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` under
`/private/tmp`):

```text
swift test --filter 'ActivationSchedule(Tests|StoreTests|SettingsModelTests|WindowControllerTests)|CodexAutomationReaderTests|AutomationReconcilerTests|SyncPromptBuilderTests|LocalizationTests'
  67 executed, 0 failures
swift test
  141 executed, 0 failures, 1 existing loopback-listener test skipped by its sandbox guard
swift build -c release
  Build complete
./build-app.sh
  Build complete; ad-hoc signed dist/Codex用量.app
codesign --verify --deep --strict dist/Codex用量.app
  exit 0
dist/Codex用量.app/Contents/MacOS/CodexQuotaMenu --check
  连接成功：每周用量：剩余 40%，5 小时用量：剩余 93%，正在执行 1
git diff --check
  exit 0 / no output
```

The historical RED command output for this final wave is unavailable because
the prior run was interrupted; the named regression tests are present and pass
fresh above. Save-failure injection remains intentionally deferred: the concrete
`UserDefaults` store has no controllable failing-save seam. No real visual GUI
session or real Codex synchronization was performed; controller-safe AppKit
harness coverage is reported above instead.

## Commit

Implementation commit: `627f0d5 fix: harden activation schedule reconciliation`.

This report correction is recorded in the subsequent documentation-only commit.
