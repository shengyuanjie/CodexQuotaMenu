# Codex Reset Monitor Single-Source Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-source reset forecast with the single stable 48-hour probability from Codex Reset Monitor across the Mac menu, local widget API, and Scriptable widget.

**Architecture:** `ForecastClient` fetches one validated `ResetForecast`; `ForecastCoordinator` owns one cached value and resolves it to `fresh`, `cached`, or `unavailable`. The same display snapshot feeds both AppKit presentation and schema-v2 mobile payloads, eliminating source reconciliation and event suppression.

**Tech Stack:** Swift 5.9, Foundation, AppKit, Network.framework, XCTest, JavaScript/Scriptable, macOS Keychain.

## Global Constraints

- The only forecast endpoint is `https://codexreset.org/api/monitor-summary`.
- The only forecast number is the next-48-hour probability.
- Automatic forecast refresh remains 5 minutes; request timeout remains 10 seconds.
- Values are fresh through 15 minutes, cached through 2 hours, and hidden after 2 hours.
- Personal quota, scheduled reset countdown, short window, and running task behavior remain unchanged.
- The widget endpoint remains read-only, Bearer-protected, and fixed at port `47821`.
- The mobile payload upgrades to `schemaVersion: 2`; schema v1 is rejected explicitly.
- No new dependencies.
- Version becomes `1.6.1`, build `15`.
- Do not push, create a PR, tag, or publish a Release without separate authorization.

---

### Task 1: Replace Forecast Models and Network Contract

**Files:**
- Modify: `Sources/CodexQuotaMenu/ForecastModels.swift`
- Modify: `Sources/CodexQuotaMenu/ForecastClient.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastParserTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastClientTests.swift`

**Interfaces:**
- Produces: `ResetForecast(probability48h: Int, calibrationState: String, fetchedAt: Date)`.
- Produces: `ForecastParser.parse(_ data: Data, fetchedAt: Date) throws -> ResetForecast`.
- Produces: `ForecastFetching.fetch(now: Date) async throws -> ResetForecast`.

- [ ] **Step 1: Write failing parser tests**

Replace the old primary/fast fixtures with real monitor-summary shapes. The success assertion uses literal values:

```swift
func testParsesMonitorSummaryIntoSingleForecast() throws {
    let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let data = Data(#"{"reset":{"calibrationState":"experimental","score48h":82,"unit":"probability"}}"#.utf8)
    let value = try ForecastParser.parse(data, fetchedAt: fetchedAt)
    XCTAssertEqual(value, ResetForecast(probability48h: 82, calibrationState: "experimental", fetchedAt: fetchedAt))
}
```

Add separate rejection tests for `score48h` -1/101, unit `percent`, missing `reset`, and string score.

- [ ] **Step 2: Verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter ForecastParserTests
```

Expected: compilation fails because `ResetForecast` and `ForecastParser.parse` do not exist.

- [ ] **Step 3: Implement the minimal single model and parser**

Delete `PrimaryForecast`, `FastForecastSignal`, both wire models, and both parse entry points. Decode only `reset.calibrationState`, `reset.score48h`, and `reset.unit`; validate the exact unit and integer range.

- [ ] **Step 4: Verify parser GREEN**

Run the same filtered suite. Expected: all `ForecastParserTests` pass.

- [ ] **Step 5: Write failing client contract tests**

Assert the request URL is exactly `https://codexreset.org/api/monitor-summary`, method is GET, timeout is 10, and the returned forecast uses the injected `now`. Keep the existing non-2xx failure behavior test.

- [ ] **Step 6: Verify client RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter ForecastClientTests
```

Expected: fail because the client still exposes `fetchPrimary` and `fetchFast`.

- [ ] **Step 7: Implement the single request**

Change the protocol and concrete client to one `fetch(now:)` method and remove the `codex-reset.com` URL entirely.

- [ ] **Step 8: Verify GREEN and commit**

Run both parser and client suites, then:

```bash
git add Sources/CodexQuotaMenu/ForecastModels.swift Sources/CodexQuotaMenu/ForecastClient.swift Tests/CodexQuotaMenuTests/ForecastParserTests.swift Tests/CodexQuotaMenuTests/ForecastClientTests.swift
git commit -m "refactor: use reset monitor as the only forecast source"
```

### Task 2: Simplify Cache, Freshness, and Coordinator

**Files:**
- Modify: `Sources/CodexQuotaMenu/ForecastCache.swift`
- Modify: `Sources/CodexQuotaMenu/ForecastPolicy.swift`
- Modify: `Sources/CodexQuotaMenu/ForecastCoordinator.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastCacheTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastPolicyTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ResetForecast` and `ForecastFetching.fetch(now:)` from Task 1.
- Produces: `ForecastDisplayStatus.fresh`, `.cached`, `.unavailable`.
- Produces: `ForecastDisplaySnapshot(status:, probability48h:, calibrationState:, updatedAt:, isCached:)`.
- Produces: cache key `globalReset.resetMonitorForecast.v2`.

- [ ] **Step 1: Write failing freshness tests**

Use a fixed `now` and literal expectations at 15 minutes, 15 minutes + 1 second, 2 hours, 2 hours + 1 second, and 5 minutes + 1 second in the future. Assert that no probability is returned for unavailable values.

- [ ] **Step 2: Verify RED**

Run `swift test --filter ForecastPolicyTests`. Expected: compilation failures for the new three-state API.

- [ ] **Step 3: Implement the minimal policy**

Resolve a single optional `ResetForecast`; remove recent-reset, strong-signal, primary/fast reconciliation, confidence, and last-reset properties.

- [ ] **Step 4: Verify policy GREEN**

Run the filtered policy suite. Expected: all pass.

- [ ] **Step 5: Write failing cache and coordinator tests**

Assert the v2 cache round-trips `ResetForecast`; assert the legacy key is removed when the cache initializes. Assert a successful refresh saves once and a failed refresh preserves a still-valid cached value. Concurrent refresh calls must still share one network task.

- [ ] **Step 6: Verify RED**

Run filtered cache and coordinator suites. Expected: failures because old cache/protocol types remain.

- [ ] **Step 7: Implement cache and coordinator**

Store only `ResetForecast`; delete the old key `globalReset.primaryForecast.v1` during initialization; replace the two concurrent fetches with one shared `Task<Result<ResetForecast, Error>, Never>`.

- [ ] **Step 8: Verify GREEN and commit**

Run all three filtered suites, then commit the six files with:

```bash
git commit -m "refactor: simplify forecast freshness and caching"
```

### Task 3: Change Mac Presentation to One 48-Hour Number

**Files:**
- Modify: `Sources/CodexQuotaMenu/MenuPresentation.swift`
- Modify: `Sources/CodexQuotaMenu/Localization.swift`
- Modify: `Sources/CodexQuotaMenu/AppDelegate.swift`
- Modify: `Tests/CodexQuotaMenuTests/MenuPresentationTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: simplified `ForecastDisplaySnapshot` from Task 2.
- Produces: title fragment `↻48h 82%` or `↻48h --`.
- Produces: details for 48-hour probability, freshness status, update time, and source name.

- [ ] **Step 1: Write failing presentation tests**

Assert the full literal title:

```swift
XCTAssertEqual(
    MenuPresentation.title(remainingPercent: 97, resetText: "6天23时", forecast: forecast48h(82), runningCount: 2),
    "Codex 97% · 6天23时 · ↻48h 82% · ▶ 2"
)
```

Add an unavailable assertion ending in `↻48h --` and localization assertions for Chinese/English fresh, delayed, unavailable, and source rows.

- [ ] **Step 2: Verify RED**

Run filtered menu and localization suites. Expected: old `↻30%` and old status strings cause failures.

- [ ] **Step 3: Implement the minimal AppKit presentation**

Use only `probability48h`; remove the 24-hour row, confidence row, and strong-signal row. Add a fixed localized source row naming Codex Reset Monitor.

- [ ] **Step 4: Verify GREEN and commit**

Run both filtered suites and commit the five files:

```bash
git commit -m "feat: show only the 48-hour reset probability"
```

### Task 4: Upgrade the Mobile Payload and Scriptable Widget

**Files:**
- Modify: `Sources/CodexQuotaMenu/WidgetPayload.swift`
- Modify: `Sources/CodexQuotaMenu/WidgetSnapshotStore.swift`
- Modify: `Tests/CodexQuotaMenuTests/WidgetPayloadTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/WidgetSnapshotStoreTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/WidgetHTTPTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/WidgetServerIntegrationTests.swift`
- Modify: `mobile/CodexQuotaWidget.js`
- Create: `mobile/CodexQuotaWidget.test.js`
- Modify: `mobile/README.md`

**Interfaces:**
- Consumes: simplified forecast snapshot from Task 2.
- Produces: widget JSON schema v2 with `probability48h`, `calibrationState`, `updatedAt`, `isCached`, and source `codexreset.org`.

- [ ] **Step 1: Write failing Swift payload tests**

Assert `schemaVersion == 2`, `probability48h == 82`, source `codexreset.org`, and absence of literal keys `probability24h`, `confidence`, `strongSignal`, and `lastResetAt`. Update default and HTTP fixtures to schema v2.

- [ ] **Step 2: Verify RED**

Run all `Widget*Tests`. Expected: payload assertions fail because production still emits schema v1.

- [ ] **Step 3: Implement the v2 payload**

Simplify `WidgetForecastPayload`, set schema 2, update the empty snapshot, and preserve all authentication/HTTP behavior.

- [ ] **Step 4: Verify Swift GREEN**

Run all `Widget*Tests`. Expected: payload, router, store, and real listener tests pass when port 47821 is free.

- [ ] **Step 5: Add a runnable Scriptable validation harness**

Refactor the top-level script so parsing/render helpers remain usable by Scriptable and can be invoked with Node-controlled fixtures. Test a valid schema-v2 fixture renders `↻48h 82%`, while schema v1 throws the explicit version mismatch and an older-than-two-hours forecast renders `↻48h --`.

- [ ] **Step 6: Verify JavaScript RED then GREEN**

Run the harness before changing parser behavior and observe the schema-v2 failure. Implement only the schema-v2 fields, then run:

```bash
node --check mobile/CodexQuotaWidget.js
node mobile/CodexQuotaWidget.test.js
```

Expected: syntax PASS and all fixture assertions PASS. If the bundled Node runtime is required, use the workspace dependency runtime.

- [ ] **Step 7: Update mobile instructions and commit**

Document the single 48-hour line and schema-v2 incompatibility, then commit all mobile/payload files:

```bash
git commit -m "feat: deliver the single-source forecast to Scriptable"
```

### Task 5: Update Documentation, Version, Build, and Install

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `PRIVACY.md`
- Modify: `PRIVACY.en.md`
- Modify: `SECURITY.md`
- Modify: `SECURITY.en.md`
- Modify: `docs/product-and-usage.md`
- Modify: `docs/product-and-usage.en.md`
- Modify: `Info.plist`
- Modify: `Sources/CodexQuotaMenu/CodexClient.swift`
- Create: `release-notes/v1.6.1.md`

**Interfaces:**
- Consumes: all implementation behavior from Tasks 1–4.
- Produces: local app v1.6.1 Build 15 and updated deliverables.

- [ ] **Step 1: Update current documentation**

Describe only Codex Reset Monitor, only 48-hour probability, the 5-minute/15-minute/2-hour rules, and schema v2. Mark release notes as `Unreleased / 未发布`.

- [ ] **Step 2: Bump local version**

Set `CFBundleShortVersionString` to `1.6.1`, `CFBundleVersion` to `15`, and the Codex app-server client version to `1.6.1`.

- [ ] **Step 3: Run source and privacy audits**

Verify active source/mobile/current docs have no runtime `codex-reset.com`, `probability24h`, `strongSignal`, or `lastResetAt`; archived superseded specifications/plans are allowed to retain historical text. Verify no secrets, `/Users/` paths, or Bearer values enter binaries or widget caches.

- [ ] **Step 4: Run the complete test suite with the installed app temporarily stopped**

```bash
pkill -x CodexQuotaMenu 2>/dev/null || true
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

Expected: all tests pass, zero failures, zero skips.

- [ ] **Step 5: Build and verify a release candidate**

```bash
./build-app.sh work/dist-v1.6.1
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' work/dist-v1.6.1/Codex用量.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' work/dist-v1.6.1/Codex用量.app/Contents/Info.plist
file work/dist-v1.6.1/Codex用量.app/Contents/MacOS/CodexQuotaMenu
codesign --verify --deep --strict work/dist-v1.6.1/Codex用量.app
```

Expected: 1.6.1, 15, arm64, valid signature.

- [ ] **Step 6: Preserve a recoverable backup and install locally**

Copy the installed v1.6.0 app to the dated outputs backup directory, replace `/Applications/Codex用量.app` with the verified candidate, and reopen it. Do not delete older backups.

- [ ] **Step 7: Verify the installed application and real source**

Run installed `--check`, fetch the public monitor-summary endpoint, wait for the app refresh, and verify its cached `probability48h` matches the live `score48h`. Confirm unauthenticated loopback and LAN widget requests return 401.

- [ ] **Step 8: Refresh user-facing outputs and hand off to the phone task**

Place the v1.6.1 app, Scriptable script, and mobile README under `/Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/`. Send the non-secret paths and schema-v2 migration note to task `019ff8d9-0e94-7543-8f9d-779a527b5b7e`; never send the Bearer token.

- [ ] **Step 9: Commit documentation and version metadata**

```bash
git commit -m "docs: document the single reset monitor source"
```

Keep branch `feature/global-reset-forecast` and its worktree unless the user separately chooses local merge or publication.
