const assert = require("node:assert/strict")
globalThis.__CODEX_WIDGET_TEST__ = true
const { validatePayload, isRecentDate } = require("./CodexQuotaWidget.js")

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
console.log("Scriptable schema v2 checks passed")
