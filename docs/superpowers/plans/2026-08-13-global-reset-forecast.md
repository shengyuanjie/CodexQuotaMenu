# Codex 全局重置预测与手机余量小组件实施计划

> **For Codex:** REQUIRED SUB-SKILLS: Use `superpowers:test-driven-development` while implementing every behavior change, then use `superpowers:verification-before-completion` before claiming completion.

**Goal:** 在不破坏现有本机用量与任务刷新链路的前提下，为 CodexQuotaMenu 增加经过校准的数据源概率、独立 Tibo 强信号，以及供 iPhone Scriptable 锁屏小组件读取的令牌保护只读接口。

**Architecture:** 本机 Codex 数据继续走现有持久 `app-server` 会话；外部预测由独立的异步协调器每五分钟获取、校验和缓存。纯函数负责概率协调、菜单文字与手机 JSON，Network.framework 服务器只提供已经生成的不可变 payload。Scriptable 只连接 Mac，不直接访问第三方预测源。

**Tech Stack:** Swift 5.9、AppKit、Foundation、Network.framework、Security.framework、XCTest、Scriptable JavaScript。

**Approved design:** `docs/superpowers/specs/2026-08-13-global-reset-forecast-design.md`

---

## 实施约束

- 所有功能先写失败测试，再写最小实现。
- 自动化测试不得访问真实第三方站点或真实 Keychain。
- 主概率只能来自 `https://codex-reset.com/api/forecast`；`codexreset.org` 只能产生 `⚡`。
- 任何第三方故障都不得覆盖或阻塞现有个人余量和任务状态。
- 手机接口默认关闭，不输出任务标题、路径、对话内容或 Codex 凭据。
- 先在本机和真机验证；未经用户再次确认，不推送、建 PR、打标签或发布 Release。

## Task 0：记录干净基线

**Files:**

- No source changes.

### Step 1：确认仓库状态和现有提交

```sh
git status --short --branch
git log -3 --oneline --decorate
```

Expected: 除已确认的设计/计划提交外没有用户未提交改动；如出现其他改动，先辨认并保留，不覆盖。

### Step 2：运行现有测试和构建

```sh
swift test
swift build
swift build -c release
```

Expected: 当前基线 18/18 测试通过，Debug/Release 构建通过。记录实际数量；如果基线失败，先按 `superpowers:systematic-debugging` 查明原因，不能把既有失败归到新功能。

### Step 3：记录已安装应用但不改动

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Codex用量.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Codex用量.app/Contents/Info.plist
file /Applications/Codex用量.app/Contents/MacOS/CodexQuotaMenu
codesign --verify --deep --strict /Applications/Codex用量.app
```

Expected: 只读确认当前 v1.5.3 Build 13、架构与签名状态；此任务不退出或替换应用。

## Task 1：建立预测领域模型与双源解析器

**Files:**

- Create: `Sources/CodexQuotaMenu/ForecastModels.swift`
- Create: `Tests/CodexQuotaMenuTests/ForecastParserTests.swift`

### Step 1：写主源成功解析的失败测试

写入固定 JSON，不访问网络：

```swift
func testParsesPrimaryForecast() throws {
    let json = #"{"updated_at":"2026-08-13T02:43:49.324Z","probabilities":{"rounded_24h":30,"rounded_48h":50},"confidence":"medium","last_reset_at":"2026-08-13T01:01:37.000Z"}"#

    let value = try ForecastParser.parsePrimary(Data(json.utf8))

    XCTAssertEqual(value.probability24h, 30)
    XCTAssertEqual(value.probability48h, 50)
    XCTAssertEqual(value.confidence, .medium)
    XCTAssertEqual(value.lastResetAt, ISO8601DateFormatter().date(from: "2026-08-13T01:01:37Z"))
}
```

同时添加以下失败测试：

- 0 与 100 的边界合法；-1、101 非法。
- 缺少 `rounded_24h` 或 `updated_at` 时失败。
- 非法日期、非法置信度和非 JSON 时失败。
- `last_reset_at` 可为 `null`。

### Step 2：运行测试确认失败

Run:

```sh
swift test --filter ForecastParserTests
```

Expected: 编译失败，提示 `ForecastParser` 尚不存在。

### Step 3：实现最小主源模型与解析

建立稳定的内部模型，不把第三方 wire model 泄漏到 UI：

```swift
enum ForecastConfidence: String, Codable, Equatable {
    case low, medium, high
}

struct PrimaryForecast: Codable, Equatable {
    let probability24h: Int
    let probability48h: Int
    let confidence: ForecastConfidence
    let updatedAt: Date
    let lastResetAt: Date?
}

enum ForecastParsingError: Error, Equatable {
    case invalidResponse
    case probabilityOutOfRange
}

enum ForecastParser {
    static func parsePrimary(_ data: Data) throws -> PrimaryForecast
}
```

使用私有 `Decodable` wire structs 和支持小数秒的 ISO 8601 formatter；解析后显式检查 0...100。

### Step 4：写快速源失败测试并实现

测试：

```swift
func testParsesFastSignalWithFetchTime() throws {
    let now = Date(timeIntervalSince1970: 1_786_589_031)
    let json = #"{"reset":{"calibrationState":"experimental","score48h":99,"unit":"probability"}}"#

    let value = try ForecastParser.parseFast(Data(json.utf8), fetchedAt: now)

    XCTAssertEqual(value.score48h, 99)
    XCTAssertEqual(value.calibrationState, "experimental")
    XCTAssertEqual(value.fetchedAt, now)
}
```

最小类型：

```swift
struct FastForecastSignal: Equatable {
    let score48h: Int
    let calibrationState: String
    let fetchedAt: Date
}
```

增加缺字段、错误单位、越界分数测试。

### Step 5：运行测试并提交

Run:

```sh
swift test --filter ForecastParserTests
git add Sources/CodexQuotaMenu/ForecastModels.swift Tests/CodexQuotaMenuTests/ForecastParserTests.swift
git commit -m "feat: parse global reset forecast sources"
```

Expected: `ForecastParserTests` 全部通过。

## Task 2：实现鲜度、缓存和双源协调规则

**Files:**

- Create: `Sources/CodexQuotaMenu/ForecastPolicy.swift`
- Create: `Sources/CodexQuotaMenu/ForecastCache.swift`
- Create: `Tests/CodexQuotaMenuTests/ForecastPolicyTests.swift`
- Create: `Tests/CodexQuotaMenuTests/ForecastCacheTests.swift`

### Step 1：写“最近重置压制 99%”失败测试

```swift
func testRecentResetSuppressesFastSignalWithoutChangingProbability() {
    let now = Date(timeIntervalSince1970: 10_000)
    let primary = fixturePrimary(
        probability24h: 30,
        updatedAt: now,
        lastResetAt: now.addingTimeInterval(-3_600)
    )
    let fast = FastForecastSignal(
        score48h: 99,
        calibrationState: "experimental",
        fetchedAt: now
    )

    let result = ForecastPolicy.resolve(primary: primary, fast: fast, now: now)

    XCTAssertEqual(result.status, .recentlyReset)
    XCTAssertFalse(result.strongSignal)
    XCTAssertEqual(result.probability24h, 30)
}
```

再写：

- 最近重置超过 6 小时且快速源 >= 90 时为 `.strongSignal`。
- 89 不触发；未知校准状态不触发。
- 快速结果超过 10 分钟不触发。
- 主源 15 分钟内为 `.forecast`。
- 15 分钟至 2 小时为 `.cached`。
- 超过 2 小时隐藏概率并变为 `.unavailable`。
- 主源时间比本机快 5 分钟以内允许；超过 5 分钟视为无效。

### Step 2：运行测试确认失败

```sh
swift test --filter ForecastPolicyTests
```

Expected: 缺少 `ForecastPolicy`。

### Step 3：实现纯策略

```swift
enum ForecastDisplayStatus: String, Codable, Equatable {
    case recentlyReset, strongSignal, forecast, cached, unavailable
}

struct ForecastDisplaySnapshot: Equatable {
    let status: ForecastDisplayStatus
    let probability24h: Int?
    let probability48h: Int?
    let confidence: ForecastConfidence?
    let strongSignal: Bool
    let lastResetAt: Date?
    let updatedAt: Date?
    let isCached: Bool
}

enum ForecastPolicy {
    static let normalAge: TimeInterval = 15 * 60
    static let maximumAge: TimeInterval = 2 * 60 * 60
    static let recentResetAge: TimeInterval = 6 * 60 * 60
    static let fastSignalMaximumAge: TimeInterval = 10 * 60

    static func resolve(
        primary: PrimaryForecast?,
        fast: FastForecastSignal?,
        now: Date
    ) -> ForecastDisplaySnapshot
}
```

策略只能读输入，不读 `Date()`、网络或磁盘。

### Step 4：写缓存失败测试

定义协议：

```swift
protocol ForecastCaching {
    func load() -> PrimaryForecast?
    func save(_ forecast: PrimaryForecast)
}
```

测试 `UserDefaultsForecastCache` 能跨实例保存/读取，损坏数据返回 `nil`，并且不会保存快速信号。

### Step 5：实现缓存并运行测试

使用 `JSONEncoder`/`JSONDecoder` 和隔离的 key `globalReset.primaryForecast.v1`。缓存只包含预测公共数据，不包含用户身份。

Run:

```sh
swift test --filter ForecastPolicyTests
swift test --filter ForecastCacheTests
git add Sources/CodexQuotaMenu/ForecastPolicy.swift Sources/CodexQuotaMenu/ForecastCache.swift Tests/CodexQuotaMenuTests/ForecastPolicyTests.swift Tests/CodexQuotaMenuTests/ForecastCacheTests.swift
git commit -m "feat: reconcile and cache reset forecasts"
```

Expected: 两组测试通过。

## Task 3：实现无用户数据的预测网络客户端与协调器

**Files:**

- Create: `Sources/CodexQuotaMenu/ForecastClient.swift`
- Create: `Sources/CodexQuotaMenu/ForecastCoordinator.swift`
- Create: `Tests/CodexQuotaMenuTests/ForecastClientTests.swift`
- Create: `Tests/CodexQuotaMenuTests/ForecastCoordinatorTests.swift`

### Step 1：写请求契约失败测试

抽象最小加载协议：

```swift
protocol HTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

用 stub 验证：

- 主源 URL 恰为 `https://codex-reset.com/api/forecast`。
- 快速源 URL 恰为 `https://codexreset.org/api/monitor-summary`。
- 方法为 GET，timeout 为 10 秒，cache policy 为 `.reloadIgnoringLocalCacheData`。
- User-Agent 只含应用名/版本，不附带个人余量或设备标识。
- 非 2xx 状态码抛出明确错误。

### Step 2：运行测试确认失败

```sh
swift test --filter ForecastClientTests
```

Expected: 缺少 `ForecastClient`。

### Step 3：实现客户端

```swift
protocol ForecastFetching {
    func fetchPrimary() async throws -> PrimaryForecast
    func fetchFast(now: Date) async throws -> FastForecastSignal
}

final class ForecastClient: ForecastFetching {
    init(loader: HTTPDataLoading, appVersion: String)
}
```

生产实现用 ephemeral `URLSessionConfiguration`：禁用 cookie、credential storage 和 URL cache，最大请求超时 10 秒。

### Step 4：写部分成功的协调器失败测试

必须覆盖：

- 两源都成功：保存主源并协调。
- 主源失败：使用两小时内缓存；快速源仍可独立返回。
- 快速源失败：主概率正常，无 `⚡`。
- 两源都失败且缓存过期：`.unavailable`。
- 同一时刻重复调用只运行一个请求批次。

建议 API：

```swift
actor ForecastCoordinator {
    init(client: ForecastFetching, cache: ForecastCaching)
    func current(now: Date) -> ForecastDisplaySnapshot
    func refresh(now: Date) async -> ForecastDisplaySnapshot
}
```

### Step 5：实现、运行并提交

```sh
swift test --filter ForecastClientTests
swift test --filter ForecastCoordinatorTests
git add Sources/CodexQuotaMenu/ForecastClient.swift Sources/CodexQuotaMenu/ForecastCoordinator.swift Tests/CodexQuotaMenuTests/ForecastClientTests.swift Tests/CodexQuotaMenuTests/ForecastCoordinatorTests.swift
git commit -m "feat: fetch reset forecasts independently"
```

Expected: 网络契约与协调器测试全部通过。

## Task 4：建立可测试的菜单栏呈现与双语文案

**Files:**

- Create: `Sources/CodexQuotaMenu/MenuPresentation.swift`
- Create: `Tests/CodexQuotaMenuTests/MenuPresentationTests.swift`
- Modify: `Sources/CodexQuotaMenu/Localization.swift`
- Modify: `Tests/CodexQuotaMenuTests/LocalizationTests.swift`

### Step 1：写标题失败测试

```swift
func testTitleAdds24HourForecastBeforeTaskCount() {
    let title = MenuPresentation.title(
        remainingPercent: 82,
        resetText: "6天23时",
        forecast: fixtureDisplay(probability24h: 30),
        runningCount: 1
    )

    XCTAssertEqual(title, "Codex 82% · 6天23时 · ↻30% · ▶ 1")
}
```

覆盖 `⚡`、`.cached`、`.unavailable`、无个人 reset 日期，以及英文倒计时输入。无可信预测必须产生 `↻--`。

### Step 2：运行测试确认失败

```sh
swift test --filter MenuPresentationTests
```

### Step 3：实现纯 formatter

```swift
enum MenuPresentation {
    static func title(
        remainingPercent: Int,
        resetText: String?,
        forecast: ForecastDisplaySnapshot,
        runningCount: Int
    ) -> String
}
```

不要让 formatter 访问 AppKit。

### Step 4：先写再实现预测文案测试

在 `LocalizationTests` 覆盖中英文：

- “全局额外重置预测” / “Global Bonus Reset Forecast”。
- “未来 24 小时：30%” / “Next 24 hours: 30%”。
- `.recentlyReset`、`.strongSignal`、`.forecast`、`.cached`、`.unavailable`。
- `⚡ Tibo 强信号，可能即将重置或正在落地`。
- 预测更新时间。
- “手机小组件”相关菜单项。

### Step 5：运行并提交

```sh
swift test --filter MenuPresentationTests
swift test --filter LocalizationTests
git add Sources/CodexQuotaMenu/MenuPresentation.swift Sources/CodexQuotaMenu/Localization.swift Tests/CodexQuotaMenuTests/MenuPresentationTests.swift Tests/CodexQuotaMenuTests/LocalizationTests.swift
git commit -m "feat: present reset probability in the menu"
```

## Task 5：把预测独立接入 AppDelegate

**Files:**

- Modify: `Sources/CodexQuotaMenu/AppDelegate.swift`
- Create: `Tests/CodexQuotaMenuTests/RefreshGateTests.swift`

### Step 1：为外部刷新节流写失败测试

把节流提取为纯类型：

```swift
struct RefreshGate {
    let interval: TimeInterval
    let manualMinimumInterval: TimeInterval
    func shouldRefresh(lastAttempt: Date?, now: Date, manual: Bool) -> Bool
}
```

测试自动五分钟、手动三十秒、首次立即刷新和未来时钟偏差。

### Step 2：实现最小节流并运行测试

```sh
swift test --filter RefreshGateTests
```

### Step 3：重构 AppDelegate 的状态渲染

修改为独立状态：

```swift
private var lastSnapshot: UsageSnapshot?
private var lastTaskSnapshot: TaskSnapshot?
private var lastForecastSnapshot = ForecastDisplaySnapshot.unavailable
private var localRefreshError: Error?
private var forecastTimer: Timer?
```

新增：

- `refreshLocal()`：保留现有 5 秒持久连接行为。
- `refreshForecast(manual:)`：在后台 `Task` 中调用 coordinator。
- `renderCurrentState()`：只组合已有状态；任何一类刷新失败都不会清空另一类。
- 启动时立刻加载缓存并显示，然后异步刷新真实接口。
- 300 秒外部 timer。
- “立即刷新”始终刷新本机；满足 30 秒门槛时才刷新外部源。

### Step 4：增加预测菜单分区

在个人用量和任务之间追加：

- 标题。
- 24h/48h。
- 置信度与状态。
- 更新时间及缓存标识。
- 可选 `⚡` 行。

保持 `--check` 只验证本机 Codex，不让第三方网络失败影响退出码。

### Step 5：运行全套测试与构建并提交

```sh
swift test
swift build
swift build -c release
git add Sources/CodexQuotaMenu/AppDelegate.swift Tests/CodexQuotaMenuTests/RefreshGateTests.swift
git commit -m "feat: integrate forecast refresh into the menu app"
```

Expected: 现有 18 项基线测试及新增测试全部通过；Debug/Release 均构建。

## Task 6：建立版本化手机 payload 与线程安全快照存储

**Files:**

- Create: `Sources/CodexQuotaMenu/WidgetPayload.swift`
- Create: `Sources/CodexQuotaMenu/WidgetSnapshotStore.swift`
- Create: `Tests/CodexQuotaMenuTests/WidgetPayloadTests.swift`
- Create: `Tests/CodexQuotaMenuTests/WidgetSnapshotStoreTests.swift`
- Modify: `Sources/CodexQuotaMenu/Models.swift`
- Modify: `Tests/CodexQuotaMenuTests/UsageParserTests.swift`

### Step 1：写周窗口选择失败测试

为 `UsageSnapshot` 增加：

```swift
var weeklyWindow: RateLimitWindow? { get }
var shortWindow: RateLimitWindow? { get }
```

测试返回顺序改变时仍按 `durationMinutes >= 10_000` 找到周窗口，而不是依赖数组索引。

### Step 2：写 payload 失败测试

```swift
func testBuildsSchemaVersionOneWithoutTaskTitles() throws {
    let payload = WidgetPayloadBuilder.build(
        usage: fixtureUsage(),
        tasks: fixtureTasks(),
        forecast: fixtureDisplay(probability24h: 30),
        generatedAt: fixedNow
    )
    let data = try JSONEncoder.widgetEncoder.encode(payload)
    let text = String(decoding: data, as: UTF8.self)

    XCTAssertEqual(payload.schemaVersion, 1)
    XCTAssertEqual(payload.quota?.weeklyRemainingPercent, 82)
    XCTAssertEqual(payload.tasks.runningCount, 1)
    XCTAssertFalse(text.contains("任务标题"))
    XCTAssertFalse(text.contains("/Users/"))
}
```

覆盖无用量、有预测、预测不可用、缓存、ISO 8601 日期和两个独立 status。

### Step 3：实现 payload

所有响应类型 `Encodable`，键名严格匹配设计文档。`source` 固定为 `codex-reset.com`，不能从不可信响应拼接。

### Step 4：写并实现线程安全快照存储

```swift
final class WidgetSnapshotStore {
    func replace(with data: Data)
    func current() -> Data
}
```

使用私有串行队列或 `NSLock`；默认 payload 必须是合法 schema v1 且状态为 unavailable。

### Step 5：运行并提交

```sh
swift test --filter UsageParserTests
swift test --filter WidgetPayloadTests
swift test --filter WidgetSnapshotStoreTests
git add Sources/CodexQuotaMenu/Models.swift Sources/CodexQuotaMenu/WidgetPayload.swift Sources/CodexQuotaMenu/WidgetSnapshotStore.swift Tests/CodexQuotaMenuTests/UsageParserTests.swift Tests/CodexQuotaMenuTests/WidgetPayloadTests.swift Tests/CodexQuotaMenuTests/WidgetSnapshotStoreTests.swift
git commit -m "feat: build privacy bounded widget payloads"
```

## Task 7：实现小组件开关、随机令牌和 Keychain 存储

**Files:**

- Modify: `Package.swift`
- Create: `Sources/CodexQuotaMenu/WidgetSecurity.swift`
- Create: `Sources/CodexQuotaMenu/WidgetPreferences.swift`
- Create: `Tests/CodexQuotaMenuTests/WidgetSecurityTests.swift`
- Create: `Tests/CodexQuotaMenuTests/WidgetPreferencesTests.swift`

### Step 1：写令牌失败测试

覆盖：

- 生成 32 字节后编码为 64 个小写十六进制字符。
- 两次生成结果不同（生产 RNG 的最小集成检查）。
- 定时安全比较对相同、不同、不同长度令牌返回正确结果。
- 输出中不含空格、换行或 URL 特殊字符。

### Step 2：实现令牌与存储协议

```swift
protocol WidgetTokenStoring {
    func load() throws -> String?
    func save(_ token: String) throws
}

enum WidgetToken {
    static func generate() throws -> String
    static func securelyEquals(_ lhs: String, _ rhs: String) -> Bool
}
```

生产 `KeychainWidgetTokenStore` 使用 service `com.local.codexquotamenu.widget`，不把令牌放进 `UserDefaults` 或日志。给 Package target 增加 Security/Network framework linker settings。

### Step 3：写开关失败测试并实现

`WidgetPreferences` 只在 `UserDefaults` 保存 `widgetServer.enabled` 布尔值；默认 `false`。测试使用独立 suite。

### Step 4：运行并提交

```sh
swift test --filter WidgetSecurityTests
swift test --filter WidgetPreferencesTests
swift build
git add Package.swift Sources/CodexQuotaMenu/WidgetSecurity.swift Sources/CodexQuotaMenu/WidgetPreferences.swift Tests/CodexQuotaMenuTests/WidgetSecurityTests.swift Tests/CodexQuotaMenuTests/WidgetPreferencesTests.swift
git commit -m "feat: protect the local widget service"
```

## Task 8：实现纯 HTTP 路由器与 Network.framework 服务器

**Files:**

- Create: `Sources/CodexQuotaMenu/WidgetHTTP.swift`
- Create: `Sources/CodexQuotaMenu/WidgetServer.swift`
- Create: `Tests/CodexQuotaMenuTests/WidgetHTTPTests.swift`

### Step 1：写路由失败测试

直接传入 HTTP bytes，覆盖：

- 正确 `GET /v1/widget` + Bearer token 返回 200 JSON。
- 缺失/错误 token 返回 401。
- 错误路径返回 404。
- POST 返回 405 且带 `Allow: GET`。
- 超过 8 KiB、畸形首行、重复 Authorization 返回 400。
- 响应 `Content-Length` 与 body 字节完全一致。
- 响应和错误里都不回显 token。

示例：

```swift
let request = Data("GET /v1/widget HTTP/1.1\r\nAuthorization: Bearer abc\r\n\r\n".utf8)
let response = WidgetHTTP.respond(request: request, expectedToken: "abc", payload: payload)
XCTAssertEqual(response.statusCode, 200)
XCTAssertEqual(response.body, payload)
```

### Step 2：实现纯 HTTP 层

```swift
struct WidgetHTTPResponse: Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    func serialized() -> Data
}

enum WidgetHTTP {
    static let maximumRequestBytes = 8 * 1024
    static func respond(request: Data, expectedToken: String, payload: Data) -> WidgetHTTPResponse
}
```

只接受单请求、`Connection: close`，不实现 keep-alive、chunked body 或写接口。

### Step 3：实现薄 Network 适配层

```swift
final class WidgetServer {
    static let port: UInt16 = 47_821
    init(tokenProvider: @escaping () -> String, payloadProvider: @escaping () -> Data)
    func start() throws
    func stop()
}
```

要求：

- `NWListener(using: .tcp, on:)`。
- 私有串行队列。
- 每连接最多读 8 KiB，超限关闭。
- 五秒未收到完整 header 则关闭。
- 处理一次请求、发送一次响应、立即关闭。
- `stateUpdateHandler` 只暴露类别，不打印 token 或请求头。

### Step 4：运行测试与构建并提交

```sh
swift test --filter WidgetHTTPTests
swift build
swift build -c release
git add Sources/CodexQuotaMenu/WidgetHTTP.swift Sources/CodexQuotaMenu/WidgetServer.swift Tests/CodexQuotaMenuTests/WidgetHTTPTests.swift
git commit -m "feat: serve authenticated widget snapshots"
```

## Task 9：把手机服务控制与实时 payload 接入菜单

**Files:**

- Create: `Sources/CodexQuotaMenu/LocalNetworkAddress.swift`
- Create: `Tests/CodexQuotaMenuTests/LocalNetworkAddressTests.swift`
- Modify: `Sources/CodexQuotaMenu/AppDelegate.swift`
- Modify: `Sources/CodexQuotaMenu/Localization.swift`
- Modify: `Tests/CodexQuotaMenuTests/LocalizationTests.swift`
- Modify: `Info.plist`

### Step 1：写地址选择失败测试

将系统接口枚举结果先转成可测试值：

```swift
struct LocalInterfaceAddress: Equatable {
    let name: String
    let address: String
    let isUp: Bool
    let isLoopback: Bool
}
```

测试优先顺序：`en0`/`en1` 的活动 IPv4、其他活动私网 IPv4、最后回退 `<hostname>.local`；永不选择 loopback 或公网地址。

### Step 2：实现地址提供者

生产实现使用 `getifaddrs`，只用于菜单里的复制地址，不参与监听权限或安全判断。

### Step 3：先写菜单文案测试

覆盖中英文：

- 手机小组件。
- 启用只读接口。
- 复制小组件地址。
- 复制访问令牌。
- 重新生成访问令牌。
- 服务启动失败。

### Step 4：接入 AppDelegate

新增“手机小组件”子菜单：

- Toggle：默认关闭；打开时确保 token 存在并启动 server。
- 复制地址：`http://<selected-address>:47821`。
- 复制 token：写入 NSPasteboard；菜单不直接显示完整 token。
- 重新生成：替换 Keychain 值，旧 token 立即失效。
- 每次本机用量、任务或预测状态变化后重新构建 payload 并写入 `WidgetSnapshotStore`。
- 应用退出时 stop listener。

Info.plist 增加清晰的 `NSLocalNetworkUsageDescription`，说明只用于用户主动启用的 iPhone 小组件。

### Step 5：运行并提交

```sh
swift test --filter LocalNetworkAddressTests
swift test --filter LocalizationTests
swift test
swift build -c release
plutil -lint Info.plist
git add Sources/CodexQuotaMenu/LocalNetworkAddress.swift Sources/CodexQuotaMenu/AppDelegate.swift Sources/CodexQuotaMenu/Localization.swift Tests/CodexQuotaMenuTests/LocalNetworkAddressTests.swift Tests/CodexQuotaMenuTests/LocalizationTests.swift Info.plist
git commit -m "feat: manage the phone widget service from the menu"
```

## Task 10：实现 Scriptable 锁屏小组件与离线降级

**Files:**

- Create: `mobile/CodexQuotaWidget.js`
- Create: `mobile/README.md`

**Primary references:**

- Scriptable `config`: `https://docs.scriptable.app/config/`
- Scriptable `Request`: `https://docs.scriptable.app/request/`
- Scriptable `Keychain`: `https://docs.scriptable.app/keychain/`
- Scriptable `ListWidget`: `https://docs.scriptable.app/listwidget/`

### Step 1：建立前台配置路径

脚本在 `config.runsInApp` 时允许：

1. 输入/修改 Mac base URL。
2. 输入/修改 token。
3. 保存到 Scriptable Keychain。
4. 测试连接并显示 accessory rectangular 预览。

若在 widget 中运行且配置缺失，只显示“请在 Scriptable 中完成配置”，不得弹窗或崩溃。

### Step 2：实现网络与安全边界

```javascript
const request = new Request(`${baseURL}/v1/widget`)
request.method = "GET"
request.headers = { Authorization: `Bearer ${token}` }
request.timeoutInterval = 10
request.allowInsecureRequest = baseURL.startsWith("http://")
const payload = await request.loadJSON()
```

要求：

- 只接受 `schemaVersion === 1`。
- 检查 status code 和字段类型。
- base URL 只允许 `http://` 私网/`.local` 或 `https://`；拒绝把 token 发往普通公网 HTTP 地址。
- token 不写入 widgetParameter、文件或日志。

### Step 3：实现本地非敏感缓存与两小时过期

- FileManager.local() 只保存最后成功 payload 和接收时间，不保存 token。
- 实时请求失败时读取缓存。
- 预测超过两小时不显示旧百分比。
- 个人余量和预测独立降级。

### Step 4：实现 accessory rectangular UI

显示：

```text
Codex 周余量 82%
6天23时后恢复 · ↻24h 30%
```

强信号使用 `⚡` 和明确文字；颜色只做辅助，因为锁屏色调可能覆盖自定义颜色。设置 `refreshAfterDate` 为当前时间后 15 分钟，同时文档明确 iOS 不保证准时刷新。

### Step 5：静态验证与提交

Run:

```sh
/Users/shengyuanjie/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node --check mobile/CodexQuotaWidget.js
rg -n "token|Authorization|writeString|Keychain" mobile/CodexQuotaWidget.js
git add mobile/CodexQuotaWidget.js mobile/README.md
git commit -m "feat: add the Scriptable quota widget"
```

Expected: JavaScript 语法通过；token 只进入 Keychain 和 Authorization header。

## Task 11：更新隐私、安全、使用说明和本地版本

**Files:**

- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `PRIVACY.md`
- Modify: `PRIVACY.en.md`
- Modify: `SECURITY.md`
- Modify: `SECURITY.en.md`
- Modify: `docs/product-and-usage.md`
- Modify: `docs/product-and-usage.en.md`
- Modify: `Info.plist`
- Create: `release-notes/v1.6.0.md`

### Step 1：先列必须披露的变化

文档必须准确说明：

- 新增两个公开第三方预测请求，且不发送个人用量或身份。
- 主概率与 `⚡` 的不同语义。
- 主概率缓存内容与两小时失效。
- 手机 API 默认关闭、Bearer token、HTTP 仅限局域网/VPN、禁止端口映射。
- Keychain/UserDefaults/Scriptable 本地缓存分别保存什么。
- Scriptable 和 iOS 后台刷新不能承诺固定周期。
- 项目仍无遥测；但“没有自行实现网络上传”的旧表述必须修正为明确列出两个预测 GET 请求。

### Step 2：更新中英文文档

确保 README、隐私、产品说明的功能和限制一致。把示例标题改为：

`Codex 90% · 4时25分 · ↻30% · ▶ 1`

### Step 3：更新本地版本但不发布

- `CFBundleShortVersionString`：`1.6.0`
- `CFBundleVersion`：`14`
- 新建本地 release note，顶部标注“未发布”。

### Step 4：检查并提交

```sh
plutil -lint Info.plist
rg -n "没有自行实现网络|不包含网络|1\.5\.3|Codex 90%" README*.md PRIVACY*.md docs/*.md
git diff --check
git add README.md README.en.md PRIVACY.md PRIVACY.en.md SECURITY.md SECURITY.en.md docs/product-and-usage.md docs/product-and-usage.en.md Info.plist release-notes/v1.6.0.md
git commit -m "docs: document forecast and widget security"
```

Expected: 不再留下与新网络行为冲突的旧文案；没有发布操作。

## Task 12：完整自动化验证与真实 HTTP 本机实测

**Files:**

- Modify only if verification exposes a bug; then return to the relevant failing test first.

### Step 1：运行完整测试与构建

```sh
swift test
swift build
swift build -c release
./build-app.sh work/dist
```

记录测试总数、Debug/Release 状态和生成 app 路径。

### Step 2：运行现有本机连接检查

```sh
work/dist/Codex用量.app/Contents/MacOS/CodexQuotaMenu --check
```

Expected: 输出个人用量与运行任务，退出码 0；外部网络不参与该退出码。

### Step 3：启动构建副本并验证菜单

- 先正常退出正在运行的已安装版本，再用 `open -n work/dist/Codex用量.app` 启动构建副本；不覆盖 `/Applications` 版本。
- 目视检查标题顺序、24h 概率、预测详情、语言切换和手动刷新。
- 临时阻断或使用测试注入分别模拟主源/辅助源失败，核对独立降级。

### Step 4：启用手机接口并做真实 HTTP 测试

读取菜单复制出的地址和 token，依次验证：

```sh
curl -i http://MAC_LAN_IP:47821/v1/widget
curl -i -H 'Authorization: Bearer REDACTED_TOKEN' http://MAC_LAN_IP:47821/v1/widget
```

Expected:

- 无 token：401。
- 正确 token：200、schemaVersion 1、合法 Content-Length。
- JSON 不含 `title`、`path`、`conversation`、`authorization` 或用户目录。

真实 token 不写入计划、日志、测试夹具或最终回复。

### Step 5：检查二进制与工作区

```sh
codesign --verify --deep --strict work/dist/Codex用量.app
file work/dist/Codex用量.app/Contents/MacOS/CodexQuotaMenu
strings - work/dist/Codex用量.app/Contents/MacOS/CodexQuotaMenu | rg '/Users/[^/]+/|Bearer [A-Za-z0-9]'
git status --short --branch
```

Expected: 签名验证通过；无编译机用户路径或真实 Bearer token；只存在预期改动。

## Task 13：本机安装、手机任务交付与真实设备验证

**Files:**

- No source changes unless verification finds a bug.

### Step 1：安全替换已安装应用

在需要写入 `/Applications` 时请求系统授权。先保存当前 v1.5.3 可恢复备份，再退出旧进程、安装 v1.6.0 本地构建并验证：

- Info.plist 为 v1.6.0 Build 14。
- 架构为当前 Mac 的原生架构。
- `codesign --verify --deep --strict` 通过。
- 菜单栏真实出现并持续更新。

备份路径和恢复方法必须告诉用户；不得执行不可恢复删除。

### Step 2：把手机交付物发送到既有 Codex 任务

向任务 `019ff8d9-0e94-7543-8f9d-779a527b5b7e` 发送：

- `mobile/CodexQuotaWidget.js` 的本地绝对路径。
- `mobile/README.md` 的配置步骤。
- Mac API 已通过的 HTTP 测试摘要。
- 明确要求手机任务不得宣称真机成功，直到用户在 iPhone 上完成验证。

### Step 3：用户侧真机检查

用户在 iPhone 上完成：

1. 将脚本导入 Scriptable。
2. 输入 Mac 地址与 token。
3. 同局域网预览。
4. 通过现有 Shadowrocket 回家链路预览。
5. 添加锁屏 accessory rectangular 小组件。
6. 检查余量、倒计时、概率、`⚡` 和离线状态。

如果失败，收集脱敏后的状态码和时间；不收集 token。

### Step 4：最终完成性检查

使用 `superpowers:verification-before-completion` 重新运行关键命令并核对：

- 所有自动化测试实际通过。
- Mac 菜单与本地 HTTP 实际通过。
- 真机项明确标记为“已验证”或“等待用户验证”。
- Git 状态和未推送提交列表清楚。
- 没有 PR、tag 或 Release，除非用户另行给出发布确认。

## 最终验收记录模板

```text
Mac 源码测试：通过/失败（N tests）
Debug/Release 构建：通过/失败
本机 Codex --check：通过/失败
菜单栏目视：通过/失败
HTTP 401/200：通过/失败
响应隐私检查：通过/失败
Scriptable 语法：通过/失败
iPhone 局域网：已验证/待用户验证
iPhone Shadowrocket：已验证/待用户验证
锁屏实际显示：已验证/待用户验证
已安装版本：版本/Build/架构
可恢复备份：路径
Git：提交列表，未推送/已推送
发布：未执行/用户明确授权后执行
```
