# Ephemeral Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Codex standalone cron activation tasks with owned macOS LaunchAgents that run `codex exec --ephemeral` and never persist recent-task conversations.

**Architecture:** Extract the existing Codex executable lookup into a reusable locator, represent owned LaunchAgents with strict label and plist validation, and put all `launchctl` effects behind an injectable controller. A transactional synchronizer stages and verifies the new schedule before removing exact-format legacy Codex automations; the existing settings model and window reconcile against the new scheduler snapshot.

**Tech Stack:** Swift 5.9, Foundation, AppKit, Swift Package Manager, macOS `launchd`/`launchctl`, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-04-ephemeral-activation-and-forecast-source-design.md`

## Global Constraints

- Manage only labels matching `com.local.codexquotamenu.activation.HHMM` with valid 24-hour times.
- Use `codex exec --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check --sandbox read-only --model gpt-5.6-luna`.
- Keep “Apply to Codex” as the only mutating action; ordinary refresh remains read-only.
- Disabled entries stay in `UserDefaults` but have no loaded LaunchAgent; deletion also removes the local row.
- Migrate only legacy Codex automations whose complete names match `CodexQuotaMenu · HH:mm`.
- Automated tests must never invoke a real Codex model request.

---

### Task 1: Reusable Codex Executable Locator

**Files:**
- Create: `Sources/CodexQuotaMenu/CodexExecutableLocator.swift`
- Modify: `Sources/CodexQuotaMenu/CodexClient.swift`
- Create: `Tests/CodexQuotaMenuTests/CodexExecutableLocatorTests.swift`

**Interfaces:**
- Consumes: `FileManager`, environment dictionary, and home directory URL.
- Produces: `CodexExecutableLocating.findExecutable() throws -> URL` and `CodexExecutableLocator`.

- [ ] **Step 1: Write the failing locator tests**

Cover ordered selection, `CODEX_CLI_PATH` precedence, rejection of non-executable candidates, and `UsageError.codexNotFound`. Use temporary executable fixture files and an injected candidate list; never depend on the developer machine’s real Codex path.

```swift
func testSelectsFirstExecutableCandidateInStableOrder() throws {
    let selected = try CodexExecutableLocator(
        candidatePaths: [missing.path, executable.path],
        isExecutable: FileManager.default.isExecutableFile(atPath:)
    ).findExecutable()
    XCTAssertEqual(selected, executable)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/cqm-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/cqm-swiftpm-module-cache \
xcrun swift test --disable-sandbox --scratch-path /private/tmp/cqm-ephemeral-build \
  --filter CodexExecutableLocatorTests
```

Expected: compilation failure because `CodexExecutableLocator` does not exist.

- [ ] **Step 3: Implement the locator and inject it into `CodexClient`**

Define:

```swift
protocol CodexExecutableLocating {
    func findExecutable() throws -> URL
}

struct CodexExecutableLocator: CodexExecutableLocating {
    let candidatePaths: [String]
    let isExecutable: (String) -> Bool
    func findExecutable() throws -> URL
}
```

The production initializer builds the same candidate order currently embedded in `CodexClient`. Change `CodexClient` to accept a locator and set `Process.executableURL` from its result. Remove the old private lookup method.

- [ ] **Step 4: Run focused and existing client/parser tests**

Run the Task 1 command without `--filter`, and expect all 166 baseline tests plus the new locator tests to pass, with only the existing loopback skip.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexQuotaMenu/CodexExecutableLocator.swift \
  Sources/CodexQuotaMenu/CodexClient.swift \
  Tests/CodexQuotaMenuTests/CodexExecutableLocatorTests.swift
git commit -m "refactor: share Codex executable lookup"
```

---

### Task 2: Strict LaunchAgent Policy and Reader

**Files:**
- Create: `Sources/CodexQuotaMenu/ActivationLaunchAgent.swift`
- Create: `Sources/CodexQuotaMenu/ActivationLaunchAgentReader.swift`
- Create: `Tests/CodexQuotaMenuTests/ActivationLaunchAgentTests.swift`
- Create: `Tests/CodexQuotaMenuTests/ActivationLaunchAgentReaderTests.swift`

**Interfaces:**
- Consumes: `ActivationTime`, Codex executable URL, home URL, `~/Library/LaunchAgents`.
- Produces: `ActivationLaunchAgentPolicy`, `ActivationLaunchAgent`, `ActivationLaunchAgentReadResult`, and `ActivationLaunchAgentReader.read() -> ActivationLaunchAgentReadResult`.

- [ ] **Step 1: Write failing policy tests**

Assert the exact label/file mapping and exact command arguments:

```swift
XCTAssertEqual(policy.label(for: sixThirty), "com.local.codexquotamenu.activation.0630")
XCTAssertEqual(agent.programArguments.prefix(4), [
    codex.path, "exec", "--ephemeral", "--ignore-user-config"
])
XCTAssertTrue(agent.programArguments.contains("--ignore-rules"))
XCTAssertEqual(agent.hour, 6)
XCTAssertEqual(agent.minute, 30)
```

Also reject labels with invalid hours/minutes, suffixes, path escapes, duplicate required plist keys, `RunAtLoad`, unexpected program arguments, non-`/dev/null` output paths, or a mismatched filename/label.

- [ ] **Step 2: Run focused tests and verify RED**

Run the standard Swift command with `--filter ActivationLaunchAgent`; expect missing-type compilation failures.

- [ ] **Step 3: Implement canonical plist generation and strict reading**

Use `PropertyListSerialization` with XML output. The canonical dictionary contains exactly:

```swift
[
    "Label": label,
    "ProgramArguments": arguments,
    "StartCalendarInterval": ["Hour": time.hour, "Minute": time.minute],
    "WorkingDirectory": home.path,
    "StandardOutPath": "/dev/null",
    "StandardErrorPath": "/dev/null"
]
```

The reader enumerates only regular `.plist` files, recognizes only exact owned filenames, validates all required values, and returns `.unavailable(reason)` on any ambiguous owned file rather than guessing.

- [ ] **Step 4: Run focused tests and then the full suite**

Expect all new reader/policy tests and all prior tests to pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexQuotaMenu/ActivationLaunchAgent.swift \
  Sources/CodexQuotaMenu/ActivationLaunchAgentReader.swift \
  Tests/CodexQuotaMenuTests/ActivationLaunchAgentTests.swift \
  Tests/CodexQuotaMenuTests/ActivationLaunchAgentReaderTests.swift
git commit -m "feat: model owned activation LaunchAgents"
```

---

### Task 3: Injectable `launchctl` Controller and Reconciliation

**Files:**
- Create: `Sources/CodexQuotaMenu/LaunchctlController.swift`
- Create: `Sources/CodexQuotaMenu/ActivationLaunchAgentReconciler.swift`
- Create: `Tests/CodexQuotaMenuTests/LaunchctlControllerTests.swift`
- Create: `Tests/CodexQuotaMenuTests/ActivationLaunchAgentReconcilerTests.swift`

**Interfaces:**
- Consumes: owned labels, plist URLs, current GUI user ID, and `ActivationScheduleEntry` values.
- Produces: `LaunchctlControlling`, `LaunchctlController`, `LaunchctlCommandRunning`, `ActivationSchedulerSnapshot`, and `ActivationLaunchAgentReconciler.evaluate(entries:snapshot:) -> AutomationSyncState`.

- [ ] **Step 1: Write failing command-construction tests**

Use a recording fake runner. Verify exact non-shell argument arrays:

```swift
XCTAssertEqual(runner.invocations, [
    ["bootstrap", "gui/501", plist.path],
    ["print", "gui/501/" + label],
    ["bootout", "gui/501/" + label]
])
```

Treat `launchctl print` exit 0 as loaded and its documented nonzero “not found” result as unloaded. Other launch errors must surface as unavailable/failure without parsing localized prose.

- [ ] **Step 2: Write failing reconciliation tests**

Cover exact sync, missing enabled agent, loaded disabled agent, extra owned agent, duplicate time, malformed owned plist, and file-present-but-not-loaded. Map these to the existing difference UI without labeling a deliberately disabled local entry as a paused Codex task.

- [ ] **Step 3: Run both focused suites and verify RED**

Use `--filter LaunchctlControllerTests` and `--filter ActivationLaunchAgentReconcilerTests`; expect missing-type failures.

- [ ] **Step 4: Implement controller and reconciler**

Run `/bin/launchctl` directly with `Process`, never through a shell. Capture bounded stderr for diagnostics but do not show raw paths in normal UI. Provide fake implementations for all tests. `ActivationSchedulerSnapshot` must include parsed owned agents and a `Set<String>` of loaded labels.

- [ ] **Step 5: Run focused and full tests**

Expect both new suites and the full project suite to pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexQuotaMenu/LaunchctlController.swift \
  Sources/CodexQuotaMenu/ActivationLaunchAgentReconciler.swift \
  Tests/CodexQuotaMenuTests/LaunchctlControllerTests.swift \
  Tests/CodexQuotaMenuTests/ActivationLaunchAgentReconcilerTests.swift
git commit -m "feat: inspect activation LaunchAgent state"
```

---

### Task 4: Transactional Schedule Synchronizer and Legacy Migration

**Files:**
- Create: `Sources/CodexQuotaMenu/ActivationLaunchAgentSynchronizer.swift`
- Modify: `Sources/CodexQuotaMenu/CodexAutomationSynchronizer.swift`
- Create: `Tests/CodexQuotaMenuTests/ActivationLaunchAgentSynchronizerTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/CodexAutomationSynchronizerTests.swift`

**Interfaces:**
- Consumes: entries, executable locator, LaunchAgent reader/controller, and legacy Codex automation root.
- Produces: `ActivationLaunchAgentSynchronizing.synchronize(entries:) throws`, `ActivationLaunchAgentSynchronizationError`, and `CodexAutomationSynchronizer.removeAllManagedAutomations() throws`.

- [ ] **Step 1: Write failing lifecycle tests**

Use temporary LaunchAgents and automations roots plus fake controller/locator. Assert:

```swift
try synchronizer.synchronize(entries: [enabledSix, disabledEleven])
XCTAssertTrue(fileExists(labelForSix))
XCTAssertFalse(fileExists(labelForEleven))
XCTAssertEqual(controller.loadedLabels, [labelForSix])
```

Then enable eleven and verify it loads; remove six from the entry list and verify its agent disappears. Assert unrelated plists and malformed prefix-sharing labels are unchanged.

- [ ] **Step 2: Write failing migration and safety tests**

Cover these exact outcomes:

- New LaunchAgents verify before legacy exact-name Codex automations are removed.
- Failure before LaunchAgent verification leaves all legacy automations untouched.
- Failure while removing legacy automations rolls back the new LaunchAgents.
- A target file created concurrently by another process is never overwritten or deleted.
- Failed rollback retains `.codexquotamenu-launchagent-recovery-<UUID>` and returns its path.
- Existing recovery directories block later synchronization.
- CLI capability probing rejects help text missing any required safety flag.

- [ ] **Step 3: Run focused synchronizer tests and verify RED**

Run with `--filter ActivationLaunchAgentSynchronizerTests`; expect missing-type failures.

- [ ] **Step 4: Implement one staged transaction**

Generate every target plist under a temporary staging directory, parse it through the production reader, back up exact owned existing files, and record hashes for files installed by this run. Boot out old owned labels, atomically move staged files, bootstrap enabled labels, then reconcile. Only after `.synced` call the narrowed legacy removal method. Rollback may remove only this run’s unchanged files and must restore/verify backups before deleting recovery data.

The capability probe invokes `[codex.path, "exec", "--help"]` with a timeout and checks separate option tokens for `--ephemeral`, `--ignore-user-config`, and `--ignore-rules`.

- [ ] **Step 5: Run focused tests and the full suite**

Expect all lifecycle, migration, collision, and rollback cases to pass with prior Codex automation safety tests unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexQuotaMenu/ActivationLaunchAgentSynchronizer.swift \
  Sources/CodexQuotaMenu/CodexAutomationSynchronizer.swift \
  Tests/CodexQuotaMenuTests/ActivationLaunchAgentSynchronizerTests.swift \
  Tests/CodexQuotaMenuTests/CodexAutomationSynchronizerTests.swift
git commit -m "feat: migrate activation schedules to ephemeral jobs"
```

---

### Task 5: Settings Window Integration

**Files:**
- Modify: `Sources/CodexQuotaMenu/ActivationScheduleSettingsModel.swift`
- Modify: `Sources/CodexQuotaMenu/ActivationScheduleWindowController.swift`
- Modify: `Sources/CodexQuotaMenu/Localization.swift`
- Modify: `Tests/CodexQuotaMenuTests/ActivationScheduleSettingsModelTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/ActivationScheduleWindowControllerTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/LocalizationTests.swift`
- Delete: `Sources/CodexQuotaMenu/AutomationReconciler.swift`
- Delete: `Tests/CodexQuotaMenuTests/AutomationReconcilerTests.swift`

**Interfaces:**
- Consumes: `ActivationSchedulerSnapshot` and `ActivationLaunchAgentSynchronizing`.
- Produces: the same user-facing model/window API, backed by LaunchAgent state.

- [ ] **Step 1: Change model tests first**

Replace Codex automation fixtures with LaunchAgent snapshots. Add a regression proving that toggling an entry off immediately changes the cached status to pending but does not call the synchronizer until `synchronize()`.

```swift
try model.update(id: entry.id, time: entry.time, isEnabled: false)
XCTAssertEqual(syncCallCount, 0)
XCTAssertPending(model.syncState)
try model.synchronize()
XCTAssertEqual(syncCallCount, 1)
```

- [ ] **Step 2: Run settings tests and verify RED**

Run `--filter ActivationScheduleSettingsModelTests`; expect type/signature failures.

- [ ] **Step 3: Wire the new reader and synchronizer**

Keep asynchronous generation-guarded scans and the ten-second visible-window timer. Update localized status/error text to say background activation jobs rather than Codex scheduled tasks. A recovery error must still display the exact retained recovery path.

- [ ] **Step 4: Run model, window, localization, then full tests**

Expect no UI regressions and no real `launchctl` or Codex execution in tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexQuotaMenu/ActivationScheduleSettingsModel.swift \
  Sources/CodexQuotaMenu/ActivationScheduleWindowController.swift \
  Sources/CodexQuotaMenu/Localization.swift \
  Tests/CodexQuotaMenuTests/ActivationScheduleSettingsModelTests.swift \
  Tests/CodexQuotaMenuTests/ActivationScheduleWindowControllerTests.swift \
  Tests/CodexQuotaMenuTests/LocalizationTests.swift
git rm Sources/CodexQuotaMenu/AutomationReconciler.swift \
  Tests/CodexQuotaMenuTests/AutomationReconcilerTests.swift
git commit -m "feat: show ephemeral activation job status"
```

---

### Task 6: Activation Documentation and Non-Consuming Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/product-and-usage.md`
- Modify: `docs/product-and-usage.en.md`
- Create: `release-notes/v1.6.7.md`

**Interfaces:**
- Consumes: final activation behavior from Tasks 1–5.
- Produces: accurate public usage, privacy, migration, and release documentation.

- [ ] **Step 1: Update documentation assertions**

Document that schedules appear only in CodexQuotaMenu, use LaunchAgents plus official ephemeral CLI calls, do not persist recent-task conversations, and may coalesce once after wake. Replace claims about writing `~/.codex/automations` with exact LaunchAgents and legacy-migration behavior.

- [ ] **Step 2: Add static regression checks**

Run:

```bash
rg -n "standalone cron|Codex.*已安排|~/.codex/automations" \
  README.md docs/product-and-usage.md docs/product-and-usage.en.md
rg -n -- "--ephemeral|LaunchAgent|launchd" \
  README.md docs/product-and-usage.md docs/product-and-usage.en.md release-notes/v1.6.7.md
```

Expected: obsolete current-runtime claims are absent; the new behavior and legacy migration are present.

- [ ] **Step 3: Run full tests without a real activation call**

Run the standard full Swift test command. Inspect generated plist fixtures and fake-runner invocations only; do not execute `codex exec` against the signed-in account.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/product-and-usage.md docs/product-and-usage.en.md \
  release-notes/v1.6.7.md
git commit -m "docs: explain ephemeral activation schedules"
```

