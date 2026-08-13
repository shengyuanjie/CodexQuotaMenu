# Scriptable Refresh Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Scriptable lock-screen widget request refreshes every five minutes, support a tap-to-refresh mode, and retain safe local refresh diagnostics without changing the visible compact text.

**Architecture:** Keep the existing single-file Scriptable artifact. Add pure helpers for run-mode resolution, refresh-date calculation, diagnostic sanitization/retention, and tap feedback; connect them to the current request/cache/render pipeline while keeping configuration available only for ordinary foreground runs.

**Tech Stack:** Scriptable JavaScriptCore, Node.js assertion tests, Scriptable Keychain/FileManager/ListWidget APIs.

## Global Constraints

- The inline text remains `剩xx% 余x天 TiboXX%` with spaces and no symbols.
- `refreshAfterDate` requests the earliest refresh at five minutes; documentation must state that iOS does not guarantee this interval.
- `Parameter: refresh` with `When Interacting: Run Script` skips configuration and performs a live request.
- Access tokens, Authorization headers, payload bodies, endpoint URLs, and credentials must never enter the diagnostic log.
- Diagnostics retain at most 200 entries from the last three days.
- Existing schema v2 validation, two-hour offline cache expiry, and Shadowrocket-to-LAN behavior remain unchanged.
- Do not modify or restart the Mac service.

---

### Task 1: Refresh scheduling, run-mode, and safe diagnostics

**Files:**
- Modify: `mobile/CodexQuotaWidget.test.js`
- Modify: `mobile/CodexQuotaWidget.js`

**Interfaces:**
- Produces: `resolveRunMode(runtimeConfig, widgetParameter) -> "widget" | "refresh" | "app"`.
- Produces: `nextRefreshDate(now) -> Date` using an exact five-minute offset.
- Produces: `makeRefreshDiagnostic(input) -> object` containing only `completedAt`, `runMode`, `source`, `outcome`, `statusCode`, and `durationMs`.
- Produces: `pruneRefreshDiagnostics(entries, now) -> object[]` retaining three days and at most 200 entries.
- Produces: `appendRefreshDiagnostic(entry, manager?) -> void`, with Scriptable `FileManager.local()` as the default storage boundary.

- [ ] **Step 1: Write failing behavior tests**

Extend the module import and add tests with hand-derived expected values:

```js
const {
  resolveRunMode,
  nextRefreshDate,
  makeRefreshDiagnostic,
  pruneRefreshDiagnostics,
  appendRefreshDiagnostic
} = require("./CodexQuotaWidget.js")

assert.equal(resolveRunMode({ runsInWidget: true, runsInApp: false }, "refresh"), "widget")
assert.equal(resolveRunMode({ runsInWidget: false, runsInApp: true }, " refresh "), "refresh")
assert.equal(resolveRunMode({ runsInWidget: false, runsInApp: true }, null), "app")

const scheduleBase = Date.parse("2026-08-13T05:00:00.000Z")
assert.equal(nextRefreshDate(scheduleBase).toISOString(), "2026-08-13T05:05:00.000Z")

const diagnostic = makeRefreshDiagnostic({
  completedAt: "2026-08-13T05:00:01.000Z",
  runMode: "refresh",
  offline: false,
  errorCode: null,
  statusCode: 200,
  durationMs: 875,
  token: "must-not-leak",
  responseBody: "must-not-leak"
})
assert.deepEqual(diagnostic, {
  completedAt: "2026-08-13T05:00:01.000Z",
  runMode: "refresh",
  source: "live",
  outcome: "success",
  statusCode: 200,
  durationMs: 875
})
assert.equal(JSON.stringify(diagnostic).includes("must-not-leak"), false)

const retentionNow = Date.parse("2026-08-13T05:00:00.000Z")
const retained = pruneRefreshDiagnostics([
  { completedAt: "2026-08-10T04:59:59.999Z", runMode: "widget" },
  ...Array.from({ length: 205 }, (_, index) => ({
    completedAt: new Date(retentionNow - (205 - index) * 1000).toISOString(),
    runMode: "widget"
  }))
], retentionNow)
assert.equal(retained.length, 200)
assert.equal(retained.at(-1).completedAt, "2026-08-13T04:59:59.000Z")

let storedLog = null
const memoryManager = {
  documentsDirectory: () => "/documents",
  joinPath: (base, name) => `${base}/${name}`,
  fileExists: () => false,
  writeString: (_, value) => { storedLog = value }
}
appendRefreshDiagnostic(diagnostic, memoryManager)
assert.deepEqual(JSON.parse(storedLog), [diagnostic])
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node mobile/CodexQuotaWidget.test.js
```

Expected: FAIL because the new helpers are not exported or defined.

- [ ] **Step 3: Implement the minimal scheduling and diagnostic helpers**

Add constants and pure helpers, then use `nextRefreshDate(Date.now())` in both widget layouts:

```js
const REFRESH_INTERVAL_MS = 5 * 60 * 1000
const DIAGNOSTIC_FILE = "CodexQuotaWidget-refresh-log-v1.json"
const DIAGNOSTIC_MAX_AGE_MS = 3 * 24 * 60 * 60 * 1000
const DIAGNOSTIC_MAX_ENTRIES = 200

function resolveRunMode(runtimeConfig, widgetParameter) {
  if (runtimeConfig?.runsInWidget) return "widget"
  return String(widgetParameter || "").trim().toLowerCase() === "refresh"
    ? "refresh"
    : "app"
}

function nextRefreshDate(now) {
  return new Date(Number(now) + REFRESH_INTERVAL_MS)
}

function makeRefreshDiagnostic(input) {
  return {
    completedAt: input.completedAt,
    runMode: ["widget", "refresh", "app"].includes(input.runMode) ? input.runMode : "app",
    source: input.offline ? (input.hasPayload ? "cache" : "none") : "live",
    outcome: input.errorCode || "success",
    statusCode: Number.isInteger(input.statusCode) ? input.statusCode : null,
    durationMs: Math.max(0, Math.round(Number(input.durationMs) || 0))
  }
}
```

Implement `pruneRefreshDiagnostics` by filtering valid dates newer than `now - DIAGNOSTIC_MAX_AGE_MS`, sorting ascending by `completedAt`, and slicing the last 200. Implement `appendRefreshDiagnostic` as fail-open FileManager JSON I/O; malformed existing JSON becomes an empty list and write failure is ignored.

- [ ] **Step 4: Run tests and syntax check to verify GREEN**

Run:

```bash
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node mobile/CodexQuotaWidget.test.js
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node --check mobile/CodexQuotaWidget.js
```

Expected: both exit 0; the test prints its success line.

- [ ] **Step 5: Commit Task 1**

```bash
git add mobile/CodexQuotaWidget.js mobile/CodexQuotaWidget.test.js
git commit -m "feat: add Scriptable refresh diagnostics"
```

### Task 2: Connect tap-to-refresh behavior and document iPhone settings

**Files:**
- Modify: `mobile/CodexQuotaWidget.test.js`
- Modify: `mobile/CodexQuotaWidget.js`
- Modify: `mobile/README.md`

**Interfaces:**
- Consumes: run modes and diagnostic helpers from Task 1.
- Produces: `formatRefreshFeedback(result, now) -> { title: string, message: string }` for live, cached, and unavailable results.
- Produces: `calculateRefreshStats(entries) -> { count, averageIntervalMinutes, minimumIntervalMinutes, maximumIntervalMinutes, lastCompletedAt }` for the local diagnostic viewer.
- Produces: foreground flow where `refresh` skips `presentConfiguration`, immediately loads data, writes diagnostics, calls `Script.setWidget`, and shows one result alert without a preview.

- [ ] **Step 1: Write failing feedback tests**

Extend the existing module destructuring import with `formatRefreshFeedback` and `calculateRefreshStats`. Add a complete schema-v2 payload fixture with weekly quota and forecast, then assert literal foreground messages and diagnostic statistics:

```js
const validLivePayload = validatePayload({
  schemaVersion: 2,
  generatedAt: "2026-08-13T05:00:00.000Z",
  quotaStatus: "fresh",
  quota: {
    primaryRemainingPercent: 90,
    primaryResetsAt: "2026-08-13T09:00:00.000Z",
    weeklyRemainingPercent: 85,
    weeklyResetsAt: "2026-08-20T05:00:00.000Z"
  },
  tasks: { runningCount: 0 },
  forecastStatus: "fresh",
  forecast: {
    probability48h: 23,
    calibrationState: "experimental",
    updatedAt: "2026-08-13T05:00:00.000Z",
    isCached: false,
    source: "codexreset.org"
  }
})

const liveFeedback = formatRefreshFeedback({
  payload: validLivePayload,
  receivedAt: "2026-08-13T05:00:00.000Z",
  offline: false,
  errorCode: null,
  statusCode: 200
}, fixedNow)
assert.deepEqual(liveFeedback, {
  title: "实时刷新成功",
  message: "剩85% 余7天 Tibo23%\n锁屏重绘时间由 iOS 决定。"
})

const cachedFeedback = formatRefreshFeedback({
  payload: validLivePayload,
  receivedAt: "2026-08-13T04:30:00.000Z",
  offline: true,
  errorCode: "network",
  statusCode: null
}, fixedNow)
assert.deepEqual(cachedFeedback, {
  title: "实时连接失败",
  message: "已使用本地缓存：剩85% 余7天 Tibo23%\n请检查 Shadowrocket 回家链路。"
})

assert.deepEqual(calculateRefreshStats([
  { completedAt: "2026-08-13T05:00:00.000Z" },
  { completedAt: "2026-08-13T05:07:00.000Z" },
  { completedAt: "2026-08-13T05:20:00.000Z" }
]), {
  count: 3,
  averageIntervalMinutes: 10,
  minimumIntervalMinutes: 7,
  maximumIntervalMinutes: 13,
  lastCompletedAt: "2026-08-13T05:20:00.000Z"
})
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node mobile/CodexQuotaWidget.test.js
```

Expected: FAIL because `formatRefreshFeedback` is not exported or defined.

- [ ] **Step 3: Implement tap-to-refresh orchestration**

At the beginning of `main`, resolve the mode from `config` and `args.widgetParameter`. Only call `presentConfiguration` for `app` mode. Around `loadCurrentOrCached`, measure elapsed time, construct the safe diagnostic, and append it. For `refresh` mode, show `formatRefreshFeedback`; for ordinary app mode, retain existing connection-error alerts and preview. Background widget mode never shows alerts.

Use this control shape:

```js
const runMode = resolveRunMode(config, args.widgetParameter)
let credentials = loadCredentials()
if (runMode === "app") credentials = await presentConfiguration(credentials) || credentials

const startedAt = Date.now()
const result = await loadCurrentOrCached(credentials)
const completedAt = Date.now()
appendRefreshDiagnostic(makeRefreshDiagnostic({
  completedAt: new Date(completedAt).toISOString(),
  runMode,
  offline: result.offline,
  hasPayload: Boolean(result.payload),
  errorCode: result.errorCode,
  statusCode: result.statusCode,
  durationMs: completedAt - startedAt
}))
```

If `refresh` mode has no credentials, show `请先手动打开 Scriptable 运行脚本并完成配置。` and do not attempt a request. `formatRefreshFeedback` must apply the same two-hour cache and forecast freshness rules as widget rendering before displaying values.

Add a second `查看刷新记录` action to the foreground configuration alert. It reads the local diagnostic JSON, calculates count/average/minimum/maximum intervals, and shows those values plus the latest completion time in a read-only alert. Selecting it must not overwrite credentials; after dismissal, the normal foreground request and preview may continue.

- [ ] **Step 4: Update the iPhone README**

Document these exact widget settings:

```text
When Interacting: Run Script
Parameter: refresh
```

Change the refresh section from 15 minutes to a five-minute earliest request, state that iOS may execute later, explain tap-to-refresh behavior, identify the three-day/200-entry safe local log, and preserve all current security and Shadowrocket guidance.

- [ ] **Step 5: Run focused and full project verification**

Run:

```bash
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node mobile/CodexQuotaWidget.test.js
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node --check mobile/CodexQuotaWidget.js
swift test
git diff --check
```

Expected: JavaScript tests pass, syntax exits 0, Swift tests report zero failures, and diff check is clean.

- [ ] **Step 6: Commit Task 2**

```bash
git add mobile/CodexQuotaWidget.js mobile/CodexQuotaWidget.test.js mobile/README.md
git commit -m "feat: add Scriptable tap refresh mode"
```

### Task 3: Refresh the delivery and installed Scriptable copies

**Files:**
- Modify: `/Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js`
- Modify: `/Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/README.md`
- Modify: `/Users/shengyuanjie/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js`

**Interfaces:**
- Consumes: verified Task 2 source and README.
- Produces: byte-identical delivery and iCloud-installed script copies; no token is copied or written.

- [ ] **Step 1: Update the delivery directory**

```bash
install -m 600 mobile/CodexQuotaWidget.js /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js
install -m 600 mobile/README.md /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/README.md
```

- [ ] **Step 2: Update the installed Scriptable iCloud copy**

```bash
install -m 600 mobile/CodexQuotaWidget.js "/Users/shengyuanjie/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
```

- [ ] **Step 3: Verify byte identity and secret boundaries**

```bash
cmp -s mobile/CodexQuotaWidget.js /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js
cmp -s mobile/README.md /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/README.md
cmp -s mobile/CodexQuotaWidget.js "/Users/shengyuanjie/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
shasum -a 256 mobile/CodexQuotaWidget.js /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js "/Users/shengyuanjie/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
rg -n "Bearer [0-9a-f]{64}|Authorization: Bearer|must-not-leak" mobile /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile || true
git status --short --branch
```

Expected: all `cmp` commands exit 0, all three script hashes match, the secret scan prints no real credential, and the worktree contains no uncommitted source changes.

The iPhone acceptance steps remain manual: set `Parameter` to `refresh`, tap from the lock screen on Wi-Fi and cellular/Shadowrocket, verify the Scriptable result alert, return to the lock screen to observe repaint timing, and collect at least 24 hours of diagnostic history before judging automatic refresh stability.
