// CodexQuotaWidget for Scriptable
// The access token is stored only in Scriptable Keychain and sent only as a Bearer header.

const KEY_BASE_URL = "com.local.codexquotamenu.base-url"
const KEY_TOKEN = "com.local.codexquotamenu.access-token"
const CACHE_FILE = "CodexQuotaWidget-cache-v1.json"
const DIAGNOSTIC_FILE = "CodexQuotaWidget-refresh-log-v1.json"
const FORECAST_MAX_AGE_MS = 2 * 60 * 60 * 1000
const FUTURE_TOLERANCE_MS = 5 * 60 * 1000
const REFRESH_INTERVAL_MS = 5 * 60 * 1000
const DIAGNOSTIC_MAX_AGE_MS = 3 * 24 * 60 * 60 * 1000
const DIAGNOSTIC_MAX_ENTRIES = 200

async function main() {
  const widgetParameter = typeof args === "undefined" ? null : args.widgetParameter
  const runMode = resolveRunMode(config, widgetParameter)
  let credentials = loadCredentials()
  if (runMode === "app") {
    const configured = await presentConfiguration(credentials)
    if (configured) credentials = configured
  }

  if (!credentials) {
    const widget = buildMessageWidget(
      "Codex 周余量 --",
      "请在 Scriptable 中完成配置"
    )
    if (runMode === "refresh") {
      Script.setWidget(widget)
      await presentMissingConfiguration()
      Script.complete()
    } else {
      await finish(widget, runMode === "app")
    }
    return
  }

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
  const widget = buildQuotaWidget(result)
  if (runMode === "refresh") {
    Script.setWidget(widget)
    await presentRefreshResult(result)
    Script.complete()
    return
  }
  if (runMode === "app" && result.errorCode) {
    await presentConnectionError(result.errorCode, result.statusCode)
  }
  await finish(widget, runMode === "app")
}

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
  const errorCodes = ["unauthorized", "invalid_payload", "http", "network"]
  const outcome = input.errorCode == null
    ? "success"
    : (errorCodes.includes(input.errorCode) ? input.errorCode : "error")
  return {
    completedAt: input.completedAt,
    runMode: ["widget", "refresh", "app"].includes(input.runMode) ? input.runMode : "app",
    source: input.offline ? (input.hasPayload ? "cache" : "none") : "live",
    outcome,
    statusCode: Number.isInteger(input.statusCode) ? input.statusCode : null,
    durationMs: Math.max(0, Math.round(Number(input.durationMs) || 0))
  }
}

function pruneRefreshDiagnostics(entries, now) {
  const cutoff = Number(now) - DIAGNOSTIC_MAX_AGE_MS
  return (Array.isArray(entries) ? entries : [])
    .filter(entry => {
      const completedTime = Date.parse(entry?.completedAt)
      return Number.isFinite(completedTime) && completedTime >= cutoff && completedTime <= Number(now)
    })
    .sort((left, right) => Date.parse(left.completedAt) - Date.parse(right.completedAt))
    .slice(-DIAGNOSTIC_MAX_ENTRIES)
}

function appendRefreshDiagnostic(entry, manager = FileManager.local()) {
  try {
    const path = manager.joinPath(manager.documentsDirectory(), DIAGNOSTIC_FILE)
    let entries = []
    if (manager.fileExists(path)) {
      const parsed = JSON.parse(manager.readString(path))
      if (Array.isArray(parsed)) entries = parsed
    }
    const now = Number.isFinite(Date.parse(entry?.completedAt))
      ? Date.parse(entry.completedAt)
      : Date.now()
    manager.writeString(path, JSON.stringify(pruneRefreshDiagnostics([...entries, entry], now)))
  } catch (_) {
    // Diagnostic failures must never block a valid widget render.
  }
}

function loadCredentials() {
  if (!Keychain.contains(KEY_BASE_URL) || !Keychain.contains(KEY_TOKEN)) return null
  const baseURL = Keychain.get(KEY_BASE_URL)
  const token = Keychain.get(KEY_TOKEN)
  try {
    return validateCredentials(baseURL, token)
  } catch (_) {
    return null
  }
}

async function presentConfiguration(existing) {
  const alert = new Alert()
  alert.title = "配置 Codex 余量小组件"
  alert.message = "先在 Mac 菜单中启用只读接口，再复制地址和访问令牌。"
  alert.addTextField("http://192.168.x.x:47821", existing?.baseURL || "")
  alert.addSecureTextField("64 位访问令牌", existing?.token || "")
  alert.addAction("保存并测试")
  alert.addAction("查看刷新记录")
  alert.addCancelAction("取消")

  const choice = await alert.presentAlert()
  if (choice === -1) return existing
  if (choice === 1) {
    await presentRefreshDiagnostics()
    return existing
  }

  try {
    const credentials = validateCredentials(
      alert.textFieldValue(0),
      alert.textFieldValue(1)
    )
    Keychain.set(KEY_BASE_URL, credentials.baseURL)
    Keychain.set(KEY_TOKEN, credentials.token)
    return credentials
  } catch (error) {
    const message = error?.message === "unsafe_url"
      ? "HTTP 地址必须是私网 IPv4 或 .local；公网地址请使用 HTTPS。"
      : "请检查地址格式和 64 位访问令牌。"
    const failure = new Alert()
    failure.title = "配置无效"
    failure.message = message
    failure.addAction("好")
    await failure.presentAlert()
    return existing
  }
}

function validateCredentials(rawBaseURL, rawToken) {
  const baseURL = String(rawBaseURL || "").trim().replace(/\/+$/, "")
  const token = String(rawToken || "").trim()
  const match = /^(https?):\/\/(\[[^\]]+\]|[^\/:?#]+)(?::(\d{1,5}))?$/.exec(baseURL)
  if (!match || match[2].includes("@")) throw new Error("invalid_credentials")

  const scheme = match[1].toLowerCase()
  const host = match[2].toLowerCase()
  const port = match[3] ? Number(match[3]) : null
  if (port !== null && (!Number.isInteger(port) || port < 1 || port > 65535)) {
    throw new Error("invalid_credentials")
  }
  if (scheme === "http" && !host.endsWith(".local") && !isPrivateIPv4(host)) {
    throw new Error("unsafe_url")
  }
  if (!/^[0-9a-f]{64}$/.test(token)) throw new Error("invalid_credentials")
  return { baseURL, token }
}

function isPrivateIPv4(host) {
  const parts = host.split(".")
  if (parts.length !== 4) return false
  const values = parts.map(part => /^\d{1,3}$/.test(part) ? Number(part) : NaN)
  if (values.some(value => !Number.isInteger(value) || value < 0 || value > 255)) return false
  if (values[0] === 10) return true
  if (values[0] === 172 && values[1] >= 16 && values[1] <= 31) return true
  return values[0] === 192 && values[1] === 168
}

async function loadCurrentOrCached(credentials) {
  try {
    const payload = await fetchPayload(credentials)
    const receivedAt = new Date().toISOString()
    saveCache(payload, receivedAt)
    return { payload, receivedAt, offline: false, errorCode: null, statusCode: 200 }
  } catch (error) {
    const cached = loadCache()
    return {
      payload: cached?.payload || null,
      receivedAt: cached?.receivedAt || null,
      offline: true,
      errorCode: error?.code || "network",
      statusCode: error?.statusCode || null
    }
  }
}

async function fetchPayload(credentials) {
  const request = new Request(`${credentials.baseURL}/v1/widget`)
  request.method = "GET"
  request.headers = { Authorization: `Bearer ${credentials.token}` }
  request.timeoutInterval = 10
  request.allowInsecureRequest = credentials.baseURL.startsWith("http://")

  let raw
  try {
    raw = await request.loadJSON()
  } catch (_) {
    const statusCode = request.response?.statusCode || null
    throw requestFailure(statusCode === 401 ? "unauthorized" : "network", statusCode)
  }
  const statusCode = request.response?.statusCode || 0
  if (statusCode !== 200) throw requestFailure("http", statusCode)
  try {
    return validatePayload(raw)
  } catch (_) {
    throw requestFailure("invalid_payload", statusCode)
  }
}

function requestFailure(code, statusCode) {
  const error = new Error(code)
  error.code = code
  error.statusCode = statusCode
  return error
}

function validatePayload(raw) {
  if (!isObject(raw) || raw.schemaVersion !== 2) throw new Error("schema_v2_required")
  const generatedAt = requiredDate(raw.generatedAt)
  const quotaStatuses = ["fresh", "unavailable"]
  const forecastStatuses = ["fresh", "cached", "unavailable"]
  if (!quotaStatuses.includes(raw.quotaStatus)) throw new Error("quota_status")
  if (!forecastStatuses.includes(raw.forecastStatus)) throw new Error("forecast_status")
  if (!isObject(raw.tasks) || !isNonnegativeInteger(raw.tasks.runningCount)) {
    throw new Error("tasks")
  }

  const quota = raw.quota == null ? null : sanitizeQuota(raw.quota)
  const forecast = raw.forecast == null ? null : sanitizeForecast(raw.forecast)
  if (raw.quotaStatus === "fresh" && quota == null) throw new Error("quota")
  if (raw.forecastStatus !== "unavailable" && forecast == null) throw new Error("forecast")

  return {
    schemaVersion: 2,
    generatedAt,
    quotaStatus: raw.quotaStatus,
    quota,
    tasks: { runningCount: raw.tasks.runningCount },
    forecastStatus: raw.forecastStatus,
    forecast
  }
}

function sanitizeQuota(raw) {
  if (!isObject(raw)) throw new Error("quota")
  return {
    weeklyRemainingPercent: nullablePercent(raw.weeklyRemainingPercent),
    weeklyResetsAt: nullableDate(raw.weeklyResetsAt),
    shortRemainingPercent: nullablePercent(raw.shortRemainingPercent),
    shortResetsAt: nullableDate(raw.shortResetsAt)
  }
}

function sanitizeForecast(raw) {
  if (!isObject(raw) || raw.source !== "codexreset.org") throw new Error("forecast")
  if (typeof raw.calibrationState !== "string" || typeof raw.isCached !== "boolean") throw new Error("forecast_flags")
  return {
    probability48h: nullablePercent(raw.probability48h),
    calibrationState: raw.calibrationState,
    updatedAt: nullableDate(raw.updatedAt),
    isCached: raw.isCached,
    source: "codexreset.org"
  }
}

function nullablePercent(value) {
  if (value == null) return null
  if (!Number.isInteger(value) || value < 0 || value > 100) throw new Error("percent")
  return value
}

function nullableDate(value) {
  if (value == null) return null
  return requiredDate(value)
}

function requiredDate(value) {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) throw new Error("date")
  return value
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function isNonnegativeInteger(value) {
  return Number.isInteger(value) && value >= 0
}

function saveCache(payload, receivedAt) {
  try {
    const manager = FileManager.local()
    const path = manager.joinPath(manager.documentsDirectory(), CACHE_FILE)
    manager.writeString(path, JSON.stringify({ receivedAt, payload }))
  } catch (_) {
    // A cache write failure must not hide a valid live response.
  }
}

function loadCache() {
  try {
    const manager = FileManager.local()
    const path = manager.joinPath(manager.documentsDirectory(), CACHE_FILE)
    if (!manager.fileExists(path)) return null
    const envelope = JSON.parse(manager.readString(path))
    const receivedAt = requiredDate(envelope.receivedAt)
    return { receivedAt, payload: validatePayload(envelope.payload) }
  } catch (_) {
    return null
  }
}

function readRefreshDiagnostics(manager = FileManager.local()) {
  try {
    const path = manager.joinPath(manager.documentsDirectory(), DIAGNOSTIC_FILE)
    if (!manager.fileExists(path)) return []
    const parsed = JSON.parse(manager.readString(path))
    return pruneRefreshDiagnostics(parsed, Date.now())
  } catch (_) {
    return []
  }
}

function buildQuotaWidget(result) {
  if (!result.payload) {
    return buildMessageWidget("Codex 周余量 --", "Mac 离线 · 暂无缓存")
  }

  const now = Date.now()
  const payload = result.payload
  const receivedTime = Date.parse(result.receivedAt || payload.generatedAt)
  const cacheAge = now - receivedTime
  const expiredOffline = result.offline && (cacheAge < -FUTURE_TOLERANCE_MS || cacheAge > FORECAST_MAX_AGE_MS)
  const quota = !expiredOffline && payload.quotaStatus === "fresh" ? payload.quota : null
  const weeklyPercent = quota?.weeklyRemainingPercent
  const title = Number.isInteger(weeklyPercent)
    ? `Codex 周余量 ${weeklyPercent}%`
    : "Codex 周余量 --"

  if (expiredOffline) return buildMessageWidget(title, "Mac 离线 · 数据已过期")

  const forecast = payload.forecast
  const probabilityUsable = forecast?.updatedAt
    ? isRecentDate(forecast.updatedAt, now)
    : false
  const probabilityValue = probabilityUsable && Number.isInteger(forecast?.probability48h)
    ? forecast.probability48h
    : null
  const probabilityText = Number.isInteger(probabilityValue)
    ? `↻48h ${probabilityValue}%`
    : null

  let detail
  let strong = false
  {
    const parts = []
    if (result.offline) parts.push("Mac 离线")
    const remaining = quota?.weeklyResetsAt ? formatRemaining(quota.weeklyResetsAt, now) : null
    if (remaining) parts.push(remaining)
    if (payload.forecastStatus === "cached" && probabilityText) {
      const updateTime = formatClock(forecast.updatedAt)
      parts.push(`预测缓存 ${updateTime}`)
    }
    parts.push(probabilityText || "↻48h --")
    detail = parts.length > 0 ? parts.join(" · ") : "余量或预测暂不可用"
  }
  const inlineText = formatInlineSummary(
    weeklyPercent,
    quota?.weeklyResetsAt || null,
    probabilityValue,
    now
  )
  return buildMessageWidget(title, detail, strong, inlineText)
}

function isRecentDate(value, now) {
  const age = now - Date.parse(value)
  return age >= -FUTURE_TOLERANCE_MS && age <= FORECAST_MAX_AGE_MS
}

function formatRemaining(value, now) {
  const seconds = Math.max(0, Math.floor((Date.parse(value) - now) / 1000))
  if (seconds >= 86400) {
    const days = Math.floor(seconds / 86400)
    const hours = Math.floor((seconds % 86400) / 3600)
    return `${days}天${hours}时后恢复`
  }
  if (seconds >= 3600) {
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    return `${hours}时${minutes}分后恢复`
  }
  return `${Math.max(1, Math.floor(seconds / 60))}分后恢复`
}

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

function inlineSummaryForResult(result, now) {
  if (!result?.payload) return "剩-- 余-- Tibo--"
  const payload = result.payload
  const receivedTime = Date.parse(result.receivedAt || payload.generatedAt)
  const cacheAge = now - receivedTime
  if (result.offline && (
    cacheAge < -FUTURE_TOLERANCE_MS ||
    cacheAge > FORECAST_MAX_AGE_MS
  )) return "剩-- 余-- Tibo--"

  const quota = payload.quotaStatus === "fresh" ? payload.quota : null
  const forecast = payload.forecast
  const probability48h = forecast?.updatedAt && isRecentDate(forecast.updatedAt, now) && Number.isInteger(forecast.probability48h)
    ? forecast.probability48h
    : null
  return formatInlineSummary(
    quota?.weeklyRemainingPercent ?? null,
    quota?.weeklyResetsAt || null,
    probability48h,
    now
  )
}

function formatRefreshFeedback(result, now) {
  if (!result?.payload) {
    return {
      title: "刷新失败",
      message: `没有可用缓存。${refreshFailureHint(result?.errorCode)}`
    }
  }

  const receivedTime = Date.parse(result.receivedAt || result.payload.generatedAt)
  const cacheAge = now - receivedTime
  const cacheExpired = result.offline && (
    cacheAge < -FUTURE_TOLERANCE_MS ||
    cacheAge > FORECAST_MAX_AGE_MS
  )
  if (cacheExpired) {
    return {
      title: "刷新失败",
      message: `本地缓存已超过两小时。${refreshFailureHint(result.errorCode)}`
    }
  }

  const summary = inlineSummaryForResult(result, now)
  if (result.offline) {
    return {
      title: "实时连接失败",
      message: `已使用本地缓存：${summary}\n${refreshFailureHint(result.errorCode)}`
    }
  }
  return {
    title: "实时刷新成功",
    message: `${summary}\n锁屏重绘时间由 iOS 决定。`
  }
}

function refreshFailureHint(errorCode) {
  if (errorCode === "unauthorized") return "请从 Mac 菜单重新复制访问令牌。"
  if (errorCode === "invalid_payload") return "Mac 与手机脚本版本不兼容。"
  if (errorCode === "http") return "Mac 接口返回错误。"
  return "请检查 Shadowrocket 回家链路。"
}

function calculateRefreshStats(entries) {
  const times = (Array.isArray(entries) ? entries : [])
    .map(entry => ({ completedAt: entry?.completedAt, time: Date.parse(entry?.completedAt) }))
    .filter(entry => Number.isFinite(entry.time))
    .sort((left, right) => left.time - right.time)
  if (times.length === 0) {
    return {
      count: 0,
      averageIntervalMinutes: null,
      minimumIntervalMinutes: null,
      maximumIntervalMinutes: null,
      lastCompletedAt: null
    }
  }

  const intervals = []
  for (let index = 1; index < times.length; index += 1) {
    const interval = times[index].time - times[index - 1].time
    if (interval >= 0) intervals.push(interval / 60000)
  }
  const rounded = value => Math.round(value * 10) / 10
  return {
    count: times.length,
    averageIntervalMinutes: intervals.length > 0
      ? rounded(intervals.reduce((sum, value) => sum + value, 0) / intervals.length)
      : null,
    minimumIntervalMinutes: intervals.length > 0 ? rounded(Math.min(...intervals)) : null,
    maximumIntervalMinutes: intervals.length > 0 ? rounded(Math.max(...intervals)) : null,
    lastCompletedAt: times[times.length - 1].completedAt
  }
}

function formatClock(value) {
  const date = new Date(value)
  const hours = String(date.getHours()).padStart(2, "0")
  const minutes = String(date.getMinutes()).padStart(2, "0")
  return `${hours}:${minutes}`
}

function buildMessageWidget(title, detail, strong = false, inlineText = "剩-- 余-- Tibo--") {
  const widget = new ListWidget()
  widget.setPadding(0, 0, 0, 0)
  if (config.widgetFamily === "accessoryInline") {
    const text = widget.addText(inlineText)
    text.font = Font.semiboldSystemFont(13)
    text.lineLimit = 1
    text.minimumScaleFactor = 0.7
    widget.refreshAfterDate = nextRefreshDate(Date.now())
    return widget
  }
  const titleText = widget.addText(title)
  titleText.font = Font.semiboldSystemFont(13)
  titleText.lineLimit = 1
  widget.addSpacer(2)
  const detailText = widget.addText(detail)
  detailText.font = Font.systemFont(10)
  detailText.lineLimit = 1
  detailText.minimumScaleFactor = 0.7
  if (strong) detailText.textColor = new Color("#FFD60A")
  widget.refreshAfterDate = nextRefreshDate(Date.now())
  return widget
}

async function presentConnectionError(code, statusCode) {
  const alert = new Alert()
  alert.title = "实时连接失败"
  if (code === "unauthorized") {
    alert.message = "访问令牌不正确或已经重新生成。请从 Mac 菜单再次复制。"
  } else if (code === "invalid_payload") {
    alert.message = "Mac 返回的数据版本或格式不受支持。"
  } else if (code === "http") {
    alert.message = `Mac 接口返回 HTTP ${statusCode || "错误"}。`
  } else {
    alert.message = "无法连接 Mac。请检查只读接口、地址、同一局域网或 Shadowrocket 回家链路。"
  }
  alert.addAction("继续预览")
  await alert.presentAlert()
}

async function presentMissingConfiguration() {
  const alert = new Alert()
  alert.title = "尚未配置"
  alert.message = "请先手动打开 Scriptable 运行脚本并完成配置。"
  alert.addAction("好")
  await alert.presentAlert()
}

async function presentRefreshResult(result) {
  const feedback = formatRefreshFeedback(result, Date.now())
  const alert = new Alert()
  alert.title = feedback.title
  alert.message = feedback.message
  alert.addAction("好")
  await alert.presentAlert()
}

async function presentRefreshDiagnostics() {
  const entries = readRefreshDiagnostics().filter(entry => entry.runMode === "widget")
  const stats = calculateRefreshStats(entries)
  const alert = new Alert()
  alert.title = "后台刷新记录"
  if (stats.count === 0) {
    alert.message = "还没有后台小组件刷新记录。"
  } else {
    const last = new Date(stats.lastCompletedAt)
    const lastText = `${last.getMonth() + 1}月${last.getDate()}日 ${formatClock(stats.lastCompletedAt)}`
    const intervalText = stats.averageIntervalMinutes == null
      ? "需要至少两次后台刷新才能计算间隔。"
      : `平均 ${stats.averageIntervalMinutes} 分钟\n最短 ${stats.minimumIntervalMinutes} 分钟\n最长 ${stats.maximumIntervalMinutes} 分钟`
    alert.message = `最近3天共 ${stats.count} 次\n${intervalText}\n最近一次 ${lastText}`
  }
  alert.addAction("好")
  await alert.presentAlert()
}

async function finish(widget, presentPreview) {
  Script.setWidget(widget)
  if (presentPreview) await widget.presentAccessoryRectangular()
  Script.complete()
}

if (typeof module !== "undefined") {
  module.exports = {
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
  }
}

if (!globalThis.__CODEX_WIDGET_TEST__) (async () => {
  try {
    await main()
  } catch (_) {
    const widget = buildMessageWidget("Codex 周余量 --", "小组件暂不可用")
    Script.setWidget(widget)
    Script.complete()
  }
})()
