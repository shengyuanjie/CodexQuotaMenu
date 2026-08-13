const assert = require("node:assert/strict")
globalThis.__CODEX_WIDGET_TEST__ = true
const {
  validatePayload,
  isRecentDate,
  formatInlineSummary,
  buildMessageWidget
} = require("./CodexQuotaWidget.js")

const now = new Date().toISOString()
const valid = validatePayload({
  schemaVersion: 2,
  generatedAt: now,
  quotaStatus: "unavailable",
  quota: null,
  tasks: { runningCount: 0 },
  forecastStatus: "fresh",
  forecast: {
    probability48h: 82,
    calibrationState: "experimental",
    updatedAt: now,
    isCached: false,
    source: "codexreset.org"
  }
})

assert.equal(valid.forecast.probability48h, 82)
assert.equal(valid.forecast.source, "codexreset.org")
assert.throws(() => validatePayload({ schemaVersion: 1 }), /schema_v2_required/)
assert.equal(isRecentDate(new Date(Date.now() - 2 * 60 * 60 * 1000 - 1).toISOString(), Date.now()), false)

const fixedNow = Date.parse("2026-08-13T05:00:00Z")
assert.equal(formatInlineSummary(85, "2026-08-20T05:00:00Z", 23, fixedNow), "剩85% 余7天 Tibo23%")
assert.equal(formatInlineSummary(85, "2026-08-13T08:40:00Z", 23, fixedNow), "剩85% 余3时 Tibo23%")
assert.equal(formatInlineSummary(85, "2026-08-13T05:40:00Z", 23, fixedNow), "剩85% 余40分 Tibo23%")
assert.equal(formatInlineSummary(85, "2026-08-13T04:59:00Z", 23, fixedNow), "剩85% 余待重置 Tibo23%")
assert.equal(formatInlineSummary(null, null, null, fixedNow), "剩-- 余-- Tibo--")

const renderedTexts = []
globalThis.config = { widgetFamily: "accessoryInline" }
globalThis.ListWidget = class {
  setPadding() {}
  addText(value) {
    const text = { value }
    renderedTexts.push(text)
    return text
  }
  addSpacer() {
    throw new Error("inline widget must not add a second row")
  }
}
globalThis.Font = { semiboldSystemFont: size => ({ size }) }
const inlineWidget = buildMessageWidget("Codex 周余量 85%", "7天后恢复 · ↻48h 23%", false, "剩85% 余7天 Tibo23%")
assert.equal(renderedTexts.length, 1)
assert.equal(renderedTexts[0].value, "剩85% 余7天 Tibo23%")
assert.equal(inlineWidget.refreshAfterDate instanceof Date, true)
console.log("Scriptable schema v2 and inline checks passed")
