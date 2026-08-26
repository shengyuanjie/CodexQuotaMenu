const assert = require("node:assert/strict")
globalThis.__CODEX_WIDGET_TEST__ = true
const {
  validatePayload,
  isRecentDate,
  formatInlineSummary,
  buildMessageWidget,
  resolveRunMode,
  nextRefreshDate,
  makeRefreshDiagnostic,
  pruneRefreshDiagnostics,
  appendRefreshDiagnostic,
  formatRefreshFeedback,
  calculateRefreshStats
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
assert.throws(() => validatePayload({
  schemaVersion: 2,
  generatedAt: now,
  quotaStatus: "unavailable",
  quota: null,
  tasks: { runningCount: 0 },
  forecastStatus: "fresh",
  forecast: {
    probability48h: 82,
    calibrationState: "a".repeat(65),
    updatedAt: now,
    isCached: false,
    source: "codexreset.org"
  }
}), /forecast_flags/)
assert.equal(isRecentDate(new Date(Date.now() - 2 * 60 * 60 * 1000 - 1).toISOString(), Date.now()), false)

const fixedNow = Date.parse("2026-08-13T05:00:00Z")
assert.equal(
  formatInlineSummary(81, "2026-08-13T08:40:00Z", 62, "2026-08-15T05:00:00Z", 79, fixedNow),
  "晌81%·3时  周62%·2天"
)
assert.equal(
  formatInlineSummary(81, "2026-08-13T08:40:00Z", 62, "2026-08-15T05:00:00Z", 80, fixedNow),
  "冲冲冲～使劲蹬啊～"
)
assert.equal(
  formatInlineSummary(null, null, null, null, null, fixedNow),
  "晌--·--  周--·--"
)

const validLivePayload = validatePayload({
  schemaVersion: 2,
  generatedAt: "2026-08-13T05:00:00.000Z",
  quotaStatus: "fresh",
  quota: {
    weeklyRemainingPercent: 85,
    weeklyResetsAt: "2026-08-20T05:00:00.000Z",
    shortRemainingPercent: 90,
    shortResetsAt: "2026-08-13T09:00:00.000Z"
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

assert.deepEqual(formatRefreshFeedback({
  payload: validLivePayload,
  receivedAt: "2026-08-13T05:00:00.000Z",
  offline: false,
  errorCode: null,
  statusCode: 200
}, fixedNow), {
  title: "实时刷新成功",
  message: "剩85% 余7天 刷23%\n锁屏重绘时间由 iOS 决定。"
})

assert.deepEqual(formatRefreshFeedback({
  payload: validLivePayload,
  receivedAt: "2026-08-13T04:30:00.000Z",
  offline: true,
  errorCode: "network",
  statusCode: null
}, fixedNow), {
  title: "实时连接失败",
  message: "已使用本地缓存：剩85% 余7天 刷23%\n请检查 Shadowrocket 回家链路。"
})

assert.deepEqual(formatRefreshFeedback({
  payload: null,
  receivedAt: null,
  offline: true,
  errorCode: "network",
  statusCode: null
}, fixedNow), {
  title: "刷新失败",
  message: "没有可用缓存。请检查 Shadowrocket 回家链路。"
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
const inlineWidget = buildMessageWidget("Codex 周余量 85%", "7天后恢复 · ↻48h 23%", false, "晌81%·3时  周62%·2天")
assert.equal(renderedTexts.length, 1)
assert.equal(renderedTexts[0].value, "晌81%·3时  周62%·2天")
assert.equal(inlineWidget.refreshAfterDate instanceof Date, true)
console.log("Scriptable schema v2 and inline checks passed")
