const assert = require("node:assert/strict")
globalThis.__CODEX_WIDGET_TEST__ = true
const {
  validatePayload,
  formatInlineSummary,
  buildMessageWidget,
  resolveRunMode,
  nextRefreshDate,
  makeRefreshDiagnostic,
  pruneRefreshDiagnostics,
  appendRefreshDiagnostic,
  loadCurrentOrCached,
  requestFailure,
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
const currentPayload = {
  schemaVersion: 2,
  generatedAt: now,
  quotaStatus: "unavailable",
  quota: null,
  tasks: { runningCount: 0 },
  forecastStatus: "fresh",
  forecast: {
    probability48h: 82,
    updatedAt: now,
    isCached: false,
    source: "willcodexreset.com"
  }
}
const valid = validatePayload(currentPayload)

assert.equal(valid.forecast.probability48h, 82)
assert.equal(valid.forecast.calibrationState, null)
assert.equal(valid.forecast.source, "willcodexreset.com")
assert.equal(valid.resetCelebrationActive, true)
assert.equal(validatePayload({
  ...currentPayload,
  forecast: { ...currentPayload.forecast, probability48h: 49 }
}).resetCelebrationActive, false)
assert.equal(validatePayload({
  ...currentPayload,
  forecast: { ...currentPayload.forecast, probability48h: 50 }
}).resetCelebrationActive, true)
assert.equal(validatePayload({
  ...currentPayload,
  forecast: { ...currentPayload.forecast, probability48h: 49 },
  resetCelebrationActive: true
}).resetCelebrationActive, true)
assert.throws(() => validatePayload({
  ...currentPayload,
  forecast: { ...currentPayload.forecast, source: "codexreset.org" }
}), /forecast/)
assert.throws(() => validatePayload({
  ...currentPayload,
  forecast: { ...currentPayload.forecast, calibrationState: null }
}), /forecast_flags/)
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
    source: "willcodexreset.com"
  }
}), /forecast_flags/)
assert.throws(() => validatePayload({
  ...currentPayload,
  forecast: { ...currentPayload.forecast, probability48h: 101 }
}), /percent/)
const fixedNow = Date.parse("2026-08-13T05:00:00Z")
assert.equal(
  formatInlineSummary(99, "2026-08-13T05:22:30Z", 99, "2026-08-14T03:30:00Z", false, fixedNow),
  "晌99·22分  周99·22时"
)
assert.equal(
  formatInlineSummary(100, "2026-08-13T05:22:30Z", 100, "2026-08-14T03:30:00Z", false, fixedNow),
  "晌满·22分  周满·22时"
)
assert.equal(
  formatInlineSummary(81, "2026-08-13T04:59:59Z", 62, "2026-08-13T05:00:00Z", false, fixedNow),
  "晌81·待  周62·待"
)
assert.equal(
  formatInlineSummary(81, "2026-08-13T08:40:00Z", 62, "2026-08-15T05:00:00Z", true, fixedNow),
  "晌81·3时 周62～冲"
)
assert.equal(
  formatInlineSummary(null, null, null, null, false, fixedNow),
  "晌--·--  周--·--"
)

assert.equal(
  formatInlineSummary(100, "2026-08-13T05:22:30Z", 100, "2026-08-14T03:30:00Z", true, fixedNow),
  "晌满·22分 周满～冲"
)
assert.equal(
  formatInlineSummary(null, null, 0, null, true, fixedNow),
  "晌--·-- 周0～冲"
)

assert.equal(
  formatInlineSummary(99, "2026-08-13T05:59:59Z", 99, "2026-08-15T05:00:00Z", true, fixedNow),
  "晌99·59分 周99～冲"
)

const resetCompletedPayload = validatePayload({
  schemaVersion: 2,
  generatedAt: "2026-08-13T05:00:00.000Z",
  quotaStatus: "fresh",
  quota: {
    weeklyRemainingPercent: 100,
    weeklyResetsAt: "2026-08-20T05:00:00.000Z",
    shortRemainingPercent: 100,
    shortResetsAt: "2026-08-13T10:00:00.000Z"
  },
  tasks: { runningCount: 0 },
  forecastStatus: "fresh",
  forecast: {
    probability48h: 90,
    updatedAt: "2026-08-13T05:00:00.000Z",
    isCached: false,
    source: "willcodexreset.com"
  },
  resetCelebrationActive: false
})
assert.equal(resetCompletedPayload.resetCelebrationActive, false)
assert.equal(
  formatInlineSummary(100, "2026-08-13T10:00:00Z", 100, "2026-08-20T05:00:00Z", resetCompletedPayload.resetCelebrationActive, fixedNow),
  "晌满·5时  周满·7天"
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
    updatedAt: "2026-08-13T05:00:00.000Z",
    isCached: false,
    source: "willcodexreset.com"
  }
})

const oldSourceFreshMacPayload = validatePayload({
  ...validLivePayload,
  forecastStatus: "fresh",
  forecast: {
    ...validLivePayload.forecast,
    calibrationState: undefined,
    updatedAt: "2026-08-01T05:00:00.000Z",
    isCached: false
  }
})

assert.deepEqual(formatRefreshFeedback({
  payload: oldSourceFreshMacPayload,
  receivedAt: "2026-08-13T05:00:00.000Z",
  offline: false,
  errorCode: null,
  statusCode: 200
}, fixedNow), {
  title: "实时刷新成功",
  message: "剩85% 余7天 刷23%\n锁屏重绘时间由 iOS 决定。"
})

assert.deepEqual(formatRefreshFeedback({
  payload: oldSourceFreshMacPayload,
  receivedAt: "2026-08-13T04:30:00.000Z",
  offline: true,
  errorCode: "network",
  statusCode: null
}, fixedNow), {
  title: "实时连接失败",
  message: "已使用本地缓存：剩85% 余7天 刷23%\n请检查 Shadowrocket 回家链路。"
})

assert.deepEqual(formatRefreshFeedback({
  payload: validLivePayload,
  receivedAt: "2026-08-13T02:59:59.999Z",
  offline: true,
  errorCode: "network",
  statusCode: null
}, fixedNow), {
  title: "刷新失败",
  message: "本地缓存已超过两小时。请检查 Shadowrocket 回家链路。"
})

assert.deepEqual(formatRefreshFeedback({
  payload: validLivePayload,
  receivedAt: null,
  offline: true,
  errorCode: "network",
  statusCode: null
}, fixedNow), {
  title: "刷新失败",
  message: "本地缓存已超过两小时。请检查 Shadowrocket 回家链路。"
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
const inlineWidget = buildMessageWidget("Codex 周余量 85%", "7天后恢复 · ↻48h 23%", false, "晌81·3时  周62·2天")
assert.equal(renderedTexts.length, 1)
assert.equal(renderedTexts[0].value, "晌81·3时  周62·2天")
assert.equal(inlineWidget.refreshAfterDate instanceof Date, true)
renderedTexts.length = 0
buildMessageWidget("Codex 周余量 62%", "↻48h 82%", false,
  formatInlineSummary(81, "2026-08-13T08:40:00Z", 62, "2026-08-15T05:00:00Z", true, fixedNow))
assert.equal(renderedTexts.length, 1)
assert.equal(renderedTexts[0].value, "晌81·3时 周62～冲")
assert.equal(renderedTexts[0].lineLimit, 1)
;(async () => {
  let attempts = 0
  let waits = 0
  const retried = await loadCurrentOrCached({}, {
    fetchPayload: async () => {
      attempts += 1
      if (attempts === 1) throw requestFailure("unauthorized", 401)
      return validLivePayload
    },
    wait: async () => { waits += 1 },
    skipCacheWrite: true,
    loadCache: () => null
  })
  assert.equal(attempts, 2)
  assert.equal(waits, 1)
  assert.equal(retried.offline, false)
  assert.equal(retried.statusCode, 200)

  attempts = 0
  const cachedAfterFailure = await loadCurrentOrCached({}, {
    fetchPayload: async () => {
      attempts += 1
      throw requestFailure("http", 503)
    },
    wait: async () => { waits += 1 },
    skipCacheWrite: true,
    loadCache: () => ({ payload: validLivePayload, receivedAt: now })
  })
  assert.equal(attempts, 2)
  assert.equal(cachedAfterFailure.offline, true)
  assert.equal(cachedAfterFailure.payload, validLivePayload)
  assert.equal(cachedAfterFailure.statusCode, 503)
  console.log("Scriptable schema v2, retry, and inline checks passed")
})().catch(error => {
  console.error(error)
  process.exitCode = 1
})
