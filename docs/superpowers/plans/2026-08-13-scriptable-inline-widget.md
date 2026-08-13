# Scriptable Inline Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iPhone lock-screen `accessoryInline` widget show weekly quota, compact reset countdown, and 48-hour global reset probability in one line.

**Architecture:** Keep schema v2 parsing and the existing rectangular renderer unchanged. Add a pure compact formatter and pass its result to an `accessoryInline` branch that creates exactly one text node; all other widget families retain the current two-line layout.

**Tech Stack:** Scriptable JavaScript, Node.js `node:assert/strict`, iCloud Scriptable document sync.

## Global Constraints

- Inline output order is exactly `剩85% 余7天 Tibo23%`.
- Only `config.widgetFamily == "accessoryInline"` uses the compact layout.
- Do not change schema v2, Keychain keys, cache behavior, API authentication, or Mac service code.
- Do not publish, push, tag, or create a release.
- iPhone lock-screen completeness must be verified by the user on the real device.

---

### Task 1: Compact inline formatter and renderer

**Files:**
- Modify: `mobile/CodexQuotaWidget.test.js`
- Modify: `mobile/CodexQuotaWidget.js`

**Interfaces:**
- Consumes: sanitized weekly percentage, ISO-8601 weekly reset timestamp, usable 48-hour probability, and current Unix time in milliseconds.
- Produces: `formatInlineSummary(weeklyPercent, weeklyResetsAt, probability48h, now) -> string` and an `accessoryInline` renderer that creates one text node.

- [ ] **Step 1: Write the failing formatter tests**

Import `formatInlineSummary` and add assertions for whole days, hours, minutes, reached reset time, and unavailable fields:

```javascript
const { validatePayload, isRecentDate, formatInlineSummary } = require("./CodexQuotaWidget.js")
const fixedNow = Date.parse("2026-08-13T05:00:00Z")
assert.equal(formatInlineSummary(85, "2026-08-20T05:00:00Z", 23, fixedNow), "剩85% 余7天 Tibo23%")
assert.equal(formatInlineSummary(85, "2026-08-13T08:40:00Z", 23, fixedNow), "剩85% 余3时 Tibo23%")
assert.equal(formatInlineSummary(85, "2026-08-13T05:40:00Z", 23, fixedNow), "剩85% 余40分 Tibo23%")
assert.equal(formatInlineSummary(85, "2026-08-13T04:59:00Z", 23, fixedNow), "剩85% 余待重置 Tibo23%")
assert.equal(formatInlineSummary(null, null, null, fixedNow), "剩-- 余-- Tibo--")
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node mobile/CodexQuotaWidget.test.js
```

Expected: FAIL because `formatInlineSummary` is not exported or defined.

- [ ] **Step 3: Implement the minimal formatter and inline renderer**

Add pure countdown and summary formatters:

```javascript
function formatInlineRemaining(value, now) {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) return "--"
  const seconds = Math.floor((Date.parse(value) - now) / 1000)
  if (seconds <= 0) return "待重置"
  if (seconds >= 86400) return `${Math.floor(seconds / 86400)}天`
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}时`
  return `${Math.max(1, Math.floor(seconds / 60))}分`
}

function formatInlineSummary(weeklyPercent, weeklyResetsAt, probability48h, now) {
  const quota = Number.isInteger(weeklyPercent) ? `${weeklyPercent}%` : "--"
  const remaining = formatInlineRemaining(weeklyResetsAt, now)
  const probability = Number.isInteger(probability48h) ? `${probability48h}%` : "--"
  return `剩${quota} 余${remaining} Tibo${probability}`
}
```

Compute the inline summary from already freshness-filtered values in `buildQuotaWidget`. Extend `buildMessageWidget` with an `inlineText` argument defaulting to `剩-- 余-- Tibo--`; when `config.widgetFamily === "accessoryInline"`, add only that text, set a single-line font, set `refreshAfterDate`, and return before building the rectangular title/detail nodes. Export `formatInlineSummary` for Node tests.

- [ ] **Step 4: Run the complete Scriptable tests and syntax check**

Run:

```bash
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node mobile/CodexQuotaWidget.test.js
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node --check mobile/CodexQuotaWidget.js
```

Expected: test prints `Scriptable schema v2 and inline checks passed`; syntax check exits 0 without output.

- [ ] **Step 5: Commit the tested mobile change**

```bash
git add mobile/CodexQuotaWidget.js mobile/CodexQuotaWidget.test.js
git commit -m "fix: fit quota summary in inline lock screen widget"
```

### Task 2: Deploy and verify the mobile artifact

**Files:**
- Modify: `/Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js`
- Modify: `/Users/shengyuanjie/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js`

**Interfaces:**
- Consumes: tested `mobile/CodexQuotaWidget.js` from Task 1.
- Produces: byte-identical delivery and Scriptable iCloud copies, with the iCloud copy set to mode `0600`.

- [ ] **Step 1: Copy the tested worktree script to the delivery artifact**

Run:

```bash
cp mobile/CodexQuotaWidget.js /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js
```

Do not change the delivery README.

- [ ] **Step 2: Replace the Scriptable iCloud copy**

Run with the required filesystem approval:

```bash
install -m 600 mobile/CodexQuotaWidget.js "/Users/shengyuanjie/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
```

Do not read, copy, or modify the Scriptable Keychain token.

- [ ] **Step 3: Verify all three copies and the installed script**

Run SHA-256 and byte-comparison checks across the worktree, delivery, and iCloud copies:

```bash
cmp -s mobile/CodexQuotaWidget.js /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js
cmp -s mobile/CodexQuotaWidget.js "/Users/shengyuanjie/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
shasum -a 256 mobile/CodexQuotaWidget.js /Users/shengyuanjie/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js "/Users/shengyuanjie/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
```

Run Node syntax and contract tests against the installed copy, and confirm `probability24h`, `confidence`, `strongSignal`, `lastResetAt`, `codex-reset.com`, embedded Bearer values, and 64-hex token-shaped strings are absent.

- [ ] **Step 4: Hand off real-device validation**

Ask the user to let iCloud finish syncing, return to lock-screen customization, and verify the top line is fully visible as `剩xx% 余x天/时/分 Tiboxx%`. Do not claim the lock-screen result before the user supplies a real-device observation.
