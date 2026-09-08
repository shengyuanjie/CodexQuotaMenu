# WillCodexReset Forecast and 50 Percent Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Codex Reset Monitor feed with WillCodexReset’s bounded public forecast summary and trigger the shared encouragement state on the first `>= 50%` reading of each high-probability cycle.

**Architecture:** Keep the existing single-source forecast coordinator, but replace its wire model and HTTP endpoint. A dedicated bounded receiver stops after a validated forecast prefix and never retains the large `events` array; v3 cache and v2 celebration state isolate the new source from stale prior-source data.

**Tech Stack:** Swift 5.9, Foundation URLSession, Codable/JSONSerialization, UserDefaults, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-04-ephemeral-activation-and-forecast-source-design.md`

## Global Constraints

- Request only `https://willcodexreset.com/api/reset-radar`.
- Accept only HTTP 2xx, `code == 0`, a valid ISO-8601 `data.updatedAt`, and integer `data.probability48h` in `0...100`.
- Retain at most 64 KiB of response prefix and never retain/cache `events`.
- Keep local fetch time separate from source update time.
- Use forecast cache key `globalReset.willCodexResetForecast.v3` and celebration key `resetCelebration.state.v2`.
- Trigger encouragement at the first `>= 50%` reading; rearm only after `< 50%`.

---

### Task 1: New Forecast Model and Parser Contract

**Files:**
- Modify: `Sources/CodexQuotaMenu/ForecastModels.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastParserTests.swift`

**Interfaces:**
- Consumes: a compact JSON object plus local `fetchedAt`.
- Produces: `ResetForecast(probability48h:sourceUpdatedAt:fetchedAt:)` and `ForecastParser.parse(_:fetchedAt:)`.

- [ ] **Step 1: Replace parser tests before production code**

Use the exact minimal fixture:

```swift
let data = Data(#"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}"#.utf8)
let value = try ForecastParser.parse(data, fetchedAt: fetchedAt)
XCTAssertEqual(value.probability48h, 99)
XCTAssertEqual(value.sourceUpdatedAt, isoDate)
XCTAssertEqual(value.fetchedAt, fetchedAt)
```

Add separate failures for nonzero code, missing data, missing/invalid update time, string/fractional/out-of-range probability, and malformed JSON. Ensure unrelated unknown keys are ignored.

- [ ] **Step 2: Run parser tests and verify RED**

Run the standard Swift command with `--filter ForecastParserTests`; expect old-schema assertions to fail.

- [ ] **Step 3: Implement the minimal wire structs**

Define private `WireResponse { code, data }` and `DataPayload { updatedAt, probability48h }`. Use a fixed ISO-8601 formatter accepting fractional seconds, validate the range, and preserve separate timestamps.

- [ ] **Step 4: Run parser and model/cache-dependent tests**

Run `--filter ForecastParserTests`, then the full suite; update only compile-time fixtures required by the new initializer.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexQuotaMenu/ForecastModels.swift \
  Tests/CodexQuotaMenuTests/ForecastParserTests.swift \
  Tests/CodexQuotaMenuTests/ForecastCoordinatorTests.swift \
  Tests/CodexQuotaMenuTests/ForecastPolicyTests.swift \
  Tests/CodexQuotaMenuTests/MenuPresentationTests.swift \
  Tests/CodexQuotaMenuTests/WidgetPayloadTests.swift
git commit -m "refactor: model WillCodexReset forecasts"
```

---

### Task 2: Bounded Forecast-Prefix Receiver and Endpoint

**Files:**
- Modify: `Sources/CodexQuotaMenu/ForecastClient.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastClientTests.swift`

**Interfaces:**
- Consumes: streamed HTTP bytes from `/api/reset-radar`.
- Produces: `ForecastPrefixAccumulator.append(_:) throws -> Data?`, returning compact valid JSON once the top-level `data.events` boundary is reached; `ForecastClient.fetch(now:)` uses the compact response.

- [ ] **Step 1: Write failing accumulator tests**

Feed one byte at a time and in arbitrary chunks. Assert it returns:

```json
{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}
```

for a response whose next field is `"events":[...]`. Add failures for an `events` substring inside a quoted string, escaped quotes, duplicate `code`/`data`/`updatedAt`/`probability48h`, wrong nesting, missing boundary before 64 KiB, and a completed response without required fields.

- [ ] **Step 2: Run client tests and verify RED**

Run `--filter ForecastClientTests`; expect `ForecastPrefixAccumulator` not found.

- [ ] **Step 3: Implement structural prefix scanning**

Track JSON string/escape state, object/array depth, and key positions rather than searching for a raw substring. Stop only when `events` is encountered as a direct key of the `data` object after all required summary keys. Construct a compact object from decoded scalar values; do not copy any event bytes. Throw `responseTooLarge` at 64 KiB and `invalidResponse` for ambiguous structure.

Update the production URL to exactly `https://willcodexreset.com/api/reset-radar`. The URLSession delegate intentionally cancels after the accumulator returns compact data and treats this internal cancellation as success. Real network errors and non-2xx status remain failures.

- [ ] **Step 4: Assert request privacy and bounded behavior**

Tests must verify GET, `Accept: application/json`, `CodexQuotaMenu/<version>` User-Agent, no authorization/cookie headers, exact URL, early completion before event payload, and rejection of an oversized prefix.

- [ ] **Step 5: Run focused and full tests**

Expect client tests and the full suite to pass without external networking.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexQuotaMenu/ForecastClient.swift \
  Tests/CodexQuotaMenuTests/ForecastClientTests.swift
git commit -m "feat: read bounded WillCodexReset summaries"
```

---

### Task 3: Cache v3 and Source Metadata

**Files:**
- Modify: `Sources/CodexQuotaMenu/ForecastCache.swift`
- Modify: `Sources/CodexQuotaMenu/ForecastPolicy.swift`
- Modify: `Sources/CodexQuotaMenu/Localization.swift`
- Modify: `Sources/CodexQuotaMenu/WidgetPayload.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastCacheTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/ForecastPolicyTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/LocalizationTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/WidgetPayloadTests.swift`

**Interfaces:**
- Consumes: `ResetForecast` with source and fetch timestamps.
- Produces: v3 persisted forecast, freshness from `fetchedAt`, displayed update time from `sourceUpdatedAt`, and widget source `willcodexreset.com`.

- [ ] **Step 1: Write failing cache and policy tests**

Assert v2 legacy data is ignored but not deleted, v3 round-trips, a fresh local fetch with older source time is fresh while displaying the older source time, and future/expired local fetch times remain unavailable according to existing tolerances.

- [ ] **Step 2: Write failing source-string tests**

Assert menu source localization and widget JSON equal `willcodexreset.com`, and `codexreset.org` is absent from current payload output.

- [ ] **Step 3: Run focused tests and verify RED**

Run filters for `ForecastCacheTests`, `ForecastPolicyTests`, `LocalizationTests`, and `WidgetPayloadTests`; expect old keys/source assertions to fail.

- [ ] **Step 4: Implement timestamp separation and source migration**

Use `fetchedAt` exclusively for age checks. Set `ForecastDisplaySnapshot.updatedAt` from `sourceUpdatedAt`. Change only the new cache key and current source labels; leave legacy keys untouched for rollback compatibility.

- [ ] **Step 5: Run focused and full tests**

Expect all cache, display, widget, and full project tests to pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexQuotaMenu/ForecastCache.swift \
  Sources/CodexQuotaMenu/ForecastPolicy.swift \
  Sources/CodexQuotaMenu/Localization.swift \
  Sources/CodexQuotaMenu/WidgetPayload.swift \
  Tests/CodexQuotaMenuTests/ForecastCacheTests.swift \
  Tests/CodexQuotaMenuTests/ForecastPolicyTests.swift \
  Tests/CodexQuotaMenuTests/LocalizationTests.swift \
  Tests/CodexQuotaMenuTests/WidgetPayloadTests.swift
git commit -m "feat: migrate forecast cache to WillCodexReset"
```

---

### Task 4: Fifty-Percent First-Crossing State

**Files:**
- Modify: `Sources/CodexQuotaMenu/ResetCelebrationPolicy.swift`
- Modify: `Sources/CodexQuotaMenu/MenuPresentation.swift`
- Modify: `Tests/CodexQuotaMenuTests/ResetCelebrationPolicyTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/MenuPresentationTests.swift`

**Interfaces:**
- Consumes: optional 48-hour forecast probability and quota observations.
- Produces: shared menu/widget `ResetCelebrationDecision` with a 50% high-cycle threshold and v2 persistence.

- [ ] **Step 1: Change threshold tests first**

Add literal boundaries:

```swift
XCTAssertFalse(evaluate(.initial, probability: 49).isActive)
let first = evaluate(.initial, probability: 50)
XCTAssertTrue(first.isActive)
XCTAssertTrue(evaluate(first.state, probability: 99).isActive)
let low = evaluate(first.state, probability: 49)
XCTAssertFalse(low.isActive)
XCTAssertTrue(evaluate(low.state, probability: 50).isActive)
```

Preserve tests for dismissal after completed reset and unavailable forecasts not rearming. Add a store test proving data under `resetCelebration.state.v1` is ignored and v2 state round-trips.

- [ ] **Step 2: Run celebration/menu tests and verify RED**

Run filters for `ResetCelebrationPolicyTests` and `MenuPresentationTests`; expect 50% cases to fail under the old 80% threshold.

- [ ] **Step 3: Define one shared threshold and v2 store key**

Add `static let threshold = 50` to `ResetCelebrationPolicy`. Use it in both policy evaluation and `MenuPresentation`’s fallback path. Change only the persistence key to `resetCelebration.state.v2`.

- [ ] **Step 4: Run focused and full tests**

Expect 49/50 boundaries, high-cycle state, reset dismissal, and menu rendering to pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexQuotaMenu/ResetCelebrationPolicy.swift \
  Sources/CodexQuotaMenu/MenuPresentation.swift \
  Tests/CodexQuotaMenuTests/ResetCelebrationPolicyTests.swift \
  Tests/CodexQuotaMenuTests/MenuPresentationTests.swift
git commit -m "feat: celebrate forecast crossing fifty percent"
```

---

### Task 5: Forecast Documentation, Version, and Live Read-Only Check

**Files:**
- Modify: `README.md`
- Modify: `docs/product-and-usage.md`
- Modify: `docs/product-and-usage.en.md`
- Modify: `release-notes/v1.6.7.md`
- Modify: `Info.plist`
- Modify: `Sources/CodexQuotaMenu/CodexClient.swift`

**Interfaces:**
- Consumes: completed activation and forecast behavior.
- Produces: v1.6.7 metadata and accurate release documentation.

- [ ] **Step 1: Update current documentation**

Replace active-runtime `codexreset.org` claims with `willcodexreset.com`, document the independent-community-source caveat, source timestamp semantics, bounded summary reading, v3 cache, and 50% first-crossing rule. Do not rewrite archived superseded design documents.

- [ ] **Step 2: Bump version metadata**

Set `CFBundleShortVersionString` to `1.6.7`, increment `CFBundleVersion` from 20 to 21, and set Codex app-server `clientInfo.version` to `1.6.7`.

- [ ] **Step 3: Run static and full verification**

```bash
git diff --check
plutil -lint Info.plist
rg -n "willcodexreset.com|50%|--ephemeral" \
  README.md docs/product-and-usage.md docs/product-and-usage.en.md release-notes/v1.6.7.md
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/cqm-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/cqm-swiftpm-module-cache \
xcrun swift test --disable-sandbox --scratch-path /private/tmp/cqm-ephemeral-build
```

Expected: lint succeeds; all tests pass except the existing sandbox-dependent loopback skip.

- [ ] **Step 4: Perform a read-only live source check**

Fetch `https://willcodexreset.com/api/reset-radar` once, confirm `code == 0`, `data.updatedAt` is parseable, and `data.probability48h` is an integer in range. Do not copy event text into logs or artifacts and do not execute a real Codex activation.

- [ ] **Step 5: Build and audit arm64 Release**

Use the repository’s existing release build/audit scripts for version 1.6.7. Verify Hardened Runtime ad-hoc signature, ZIP integrity, arm64 architecture, absence of developer absolute paths, and expected version/build values.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/product-and-usage.md docs/product-and-usage.en.md \
  release-notes/v1.6.7.md Info.plist Sources/CodexQuotaMenu/CodexClient.swift
git commit -m "release: prepare v1.6.7 ephemeral activation"
```

