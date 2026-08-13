# Codex Reset Monitor 单一概率源设计

日期：2026-08-13  
状态：已获用户口头确认，待书面复核  
替代：`2026-08-13-global-reset-forecast-design.md` 中的双源预测设计

## 1. 目标

将 CodexQuotaMenu 的全局额外重置预测彻底简化为一个数据源、一个时间窗口和一套鲜度规则：

- 唯一来源：`https://codexreset.org/api/monitor-summary`
- 唯一数值：未来 48 小时全局额外重置概率
- Mac 菜单栏与 iPhone Scriptable 小组件使用同一快照
- 删除 `codex-reset.com`、双源融合、强信号阈值和最近重置抑制逻辑

个人周余量、个人计划内重置倒计时、5 小时窗口和运行任务数量保持现有行为，不受外部预测故障影响。

## 2. 数据契约

应用每次只请求：

`GET https://codexreset.org/api/monitor-summary`

只读取以下字段：

```json
{
  "reset": {
    "calibrationState": "experimental",
    "score48h": 82,
    "unit": "probability"
  }
}
```

校验规则：

- `unit` 必须为 `probability`。
- `score48h` 必须是 0–100 的整数。
- `calibrationState` 作为来源状态保留，但不参与隐藏、降权或覆盖概率。
- 缺字段、类型错误、越界、非成功 HTTP 状态或超时均视为本次刷新失败。
- `fetchedAt` 由 Mac 在成功解析响应时记录；不从网页或其他来源推断。

应用不再请求或解析 `codex-reset.com`，也不抓取 `codexreset.org` 网页中的24小时概率。

## 3. 内部模型与状态

内部预测模型只包含：

- `probability48h`
- `calibrationState`
- `fetchedAt`

展示快照只包含：

- `status`：`fresh`、`cached` 或 `unavailable`
- `probability48h`
- `calibrationState`
- `updatedAt`
- `isCached`

不再存在以下概念：

- 24小时概率
- 主源与快速源
- `strongSignal` / `⚡`
- `recentlyReset`
- `lastResetAt`
- 多来源置信度
- 不同来源的平均、覆盖或抑制规则

## 4. 刷新、缓存与故障隔离

- 外部概率自动刷新间隔保持5分钟。
- 手动刷新时，若距上次外部请求至少30秒，则同时刷新概率。
- 单次网络请求超时10秒。
- 成功响应立即持久化为唯一预测缓存。
- 成功抓取后15分钟内为 `fresh`。
- 超过15分钟且不超过2小时为 `cached`，继续显示数值并在详情标注数据延迟。
- 超过2小时为 `unavailable`，不显示旧数值。
- 系统时钟回拨或未来时间超过5分钟时，不使用该缓存。
- 概率刷新失败不能阻塞或清空仍在有效期内的缓存，也不能影响本机 Codex 用量和任务刷新。

旧版 `codex-reset.com` 缓存与新模型不兼容。升级后忽略并移除旧缓存键，不迁移旧概率，首次成功请求前显示不可用。

## 5. Mac 菜单栏

菜单栏正常示例：

`Codex 97% · 6天23时 · ↻48h 82% · ▶ 2`

规则：

- `↻48h 82%` 明确表示未来48小时的全局额外重置概率。
- 无有效值时显示 `↻48h --`。
- 不显示24小时概率、闪电标记或来源融合状态。

下拉菜单的预测区精简为：

```text
全局额外重置预测
未来 48 小时：82%
状态：实时 / 数据延迟 / 暂不可用
预测更新：11:43
来源：Codex Reset Monitor
```

预测措辞不得与个人计划内重置倒计时混淆。

## 6. 手机接口

现有鉴权、端口、只读范围和隐私边界保持不变。`GET /v1/widget` 的响应升级到 `schemaVersion: 2`，预测部分精简为：

```json
{
  "schemaVersion": 2,
  "generatedAt": "2026-08-13T03:50:00Z",
  "quotaStatus": "fresh",
  "quota": {
    "weeklyRemainingPercent": 97,
    "weeklyResetsAt": "2026-08-20T03:38:08Z",
    "shortRemainingPercent": 64,
    "shortResetsAt": "2026-08-13T07:00:00Z"
  },
  "tasks": {
    "runningCount": 2
  },
  "forecastStatus": "fresh",
  "forecast": {
    "probability48h": 82,
    "calibrationState": "experimental",
    "updatedAt": "2026-08-13T03:48:00Z",
    "isCached": false,
    "source": "codexreset.org"
  }
}
```

从响应中删除 `probability24h`、`confidence`、`strongSignal` 和 `lastResetAt`。接口仍不得包含任务标题、文件路径、对话、Codex 凭据或小组件访问令牌。

## 7. Scriptable 小组件

- 只接受 `schemaVersion: 2` 和 `forecast.source == "codexreset.org"`。
- 预测行固定显示 `↻48h 82%`。
- 预测超过2小时或状态不可用时显示 `↻48h --`，不显示过期百分比。
- 周余量、个人重置倒计时、缓存和 Keychain 行为保持不变。
- 地址和访问令牌仍只保存在 Scriptable Keychain；非敏感快照缓存不得包含令牌。
- 旧版 `schemaVersion: 1` 明确报配置/版本不匹配，避免静默误读旧字段。

## 8. 测试与验收

实现采用测试驱动，最低验收包括：

1. 解析合法的 `score48h`，拒绝错误单位、缺字段、越界和错误类型。
2. 客户端只请求 `codexreset.org/api/monitor-summary`；除被本规格替代的历史设计记录外，源码和当前说明不再描述运行时 `codex-reset.com` 请求。
3. 鲜度在15分钟和2小时边界正确切换，未来时间被拒绝。
4. 刷新失败时保留仍有效的缓存，超过2小时隐藏数值。
5. 菜单栏精确显示 `↻48h xx%` 或 `↻48h --`。
6. 手机 JSON 为 schema v2，且没有被删除字段和敏感内容。
7. Scriptable 语法检查通过，并正确拒绝 schema v1。
8. 完整 Swift 测试、Release 构建、签名验证和已安装应用 `--check` 通过。
9. 真实接口请求成功后，确认缓存和菜单使用同一个48小时数值。

## 9. 交付边界

- 更新本地 Mac 应用、手机交付脚本及说明。
- 保留旧版应用的可恢复备份。
- 不创建 PR、不推送、不打标签、不发布 Release，除非用户另行明确授权。
- iPhone 锁屏刷新仍须用户实机验证，不能仅凭脚本或 Mac 接口成功宣称完成。
