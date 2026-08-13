# Scriptable Refresh Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the iPhone Scriptable refresh-probability label `Tibo` with `刷` in the compact lock-screen summary and tap-refresh feedback.

**Architecture:** Preserve the existing single `formatInlineSummary` source of truth and change only its user-visible label plus default unavailable text. Update behavior tests first, then synchronize the verified script and current mobile README to delivery and iCloud copies.

**Tech Stack:** Scriptable JavaScriptCore, Node.js assertion tests, Git worktree.

## Global Constraints

- Normal output is exactly `剩82% 余6天 刷23%`.
- Unavailable output is exactly `剩-- 余-- 刷--`.
- Existing spaces, order, font, single-line layout, scaling, API schema, refresh timing, cache, and diagnostics remain unchanged.
- Do not alter Mac menu wording or historical documents that describe Tibo as a person or prior source.

---

### Task 1: Change the current Scriptable label with TDD

**Files:**
- Modify: `mobile/CodexQuotaWidget.test.js`
- Modify: `mobile/CodexQuotaWidget.js`
- Modify: `mobile/README.md`

**Interfaces:**
- Consumes: existing `formatInlineSummary(weeklyPercent, weeklyResetsAt, probability48h, now) -> string`.
- Produces: the same function returning `刷`-labelled summaries, reused by inline rendering and tap-refresh feedback.

- [ ] **Step 1: Write failing behavior expectations**

Change the literal expectations in `mobile/CodexQuotaWidget.test.js` to:

```js
assert.equal(formatInlineSummary(85, "2026-08-20T05:00:00Z", 23, fixedNow), "剩85% 余7天 刷23%")
assert.equal(formatInlineSummary(85, "2026-08-13T08:40:00Z", 23, fixedNow), "剩85% 余3时 刷23%")
assert.equal(formatInlineSummary(85, "2026-08-13T05:40:00Z", 23, fixedNow), "剩85% 余40分 刷23%")
assert.equal(formatInlineSummary(85, "2026-08-13T04:59:00Z", 23, fixedNow), "剩85% 余待重置 刷23%")
assert.equal(formatInlineSummary(null, null, null, fixedNow), "剩-- 余-- 刷--")
```

Change live, cached, and rendered text expectations from `Tibo23%` to `刷23%`.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
/Users/example/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node mobile/CodexQuotaWidget.test.js
```

Expected: FAIL with actual text still containing `Tibo`.

- [ ] **Step 3: Implement the minimal label change**

In `mobile/CodexQuotaWidget.js`, make `formatInlineSummary` return:

```js
return `剩${quota} 余${remaining} 刷${probability}`
```

Change the unavailable fallback in `inlineSummaryForResult` and the default `inlineText` in `buildMessageWidget` to `剩-- 余-- 刷--`.

Update `mobile/README.md` only where it describes the current visible summary, adding the example `剩82% 余6天 刷23%`; do not rewrite historical plans or specifications.

- [ ] **Step 4: Verify GREEN and commit**

Run:

```bash
/Users/example/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node mobile/CodexQuotaWidget.test.js
/Users/example/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node --check mobile/CodexQuotaWidget.js
git diff --check
```

Expected: all commands exit 0.

Commit:

```bash
git add mobile/CodexQuotaWidget.js mobile/CodexQuotaWidget.test.js mobile/README.md
git commit -m "style: rename Scriptable refresh label"
```

### Task 2: Synchronize verified mobile artifacts

**Files:**
- Modify: `/Users/example/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js`
- Modify: `/Users/example/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/README.md`
- Modify: `/Users/example/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js`

**Interfaces:**
- Consumes: tested Task 1 source and README.
- Produces: byte-identical source, delivery, and Scriptable iCloud script copies.

- [ ] **Step 1: Install the delivery and iCloud copies**

```bash
install -m 600 mobile/CodexQuotaWidget.js /Users/example/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js
install -m 600 mobile/README.md /Users/example/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/README.md
install -m 600 mobile/CodexQuotaWidget.js "/Users/example/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
```

- [ ] **Step 2: Verify identity, visible output, and secret boundaries**

```bash
cmp -s mobile/CodexQuotaWidget.js /Users/example/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js
cmp -s mobile/README.md /Users/example/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/README.md
cmp -s mobile/CodexQuotaWidget.js "/Users/example/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
shasum -a 256 mobile/CodexQuotaWidget.js /Users/example/Documents/Codex/2026-08-13/w/outputs/CodexQuotaMenu-v1.6.1-local/mobile/CodexQuotaWidget.js "/Users/example/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/CodexQuotaWidget.js"
rg -n "Tibo" mobile/CodexQuotaWidget.js mobile/CodexQuotaWidget.test.js mobile/README.md
```

Expected: all `cmp` commands exit 0, all script hashes match, and the final `rg` command prints no matches. A separate credential-pattern scan must print no embedded 64-character Bearer token.

The iPhone lock-screen repaint and final visual appearance remain a real-device check.
