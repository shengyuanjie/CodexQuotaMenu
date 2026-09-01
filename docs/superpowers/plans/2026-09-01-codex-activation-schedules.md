# Codex Activation Schedules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native settings window that stores user-selected daily activation times, generates one official Codex Scheduled Tasks reconciliation prompt, and read-only verifies the resulting local task configuration.

**Architecture:** Keep desired times in `UserDefaults`, read actual managed tasks from `~/.codex/automations/*/automation.toml`, and reconcile the two through pure Foundation types. A programmatic AppKit window edits the list and copies/opens the prompt; only observed local configuration can move the UI to “synced.”

**Tech Stack:** Swift 5.9, AppKit, Foundation, XCTest, Swift Package Manager, macOS 14+

**Spec:** `docs/superpowers/specs/2026-09-01-codex-activation-schedules-design.md`

## Global Constraints

- First launch is empty; do not prefill 06:00 or 11:02.
- Only exact names matching `CodexQuotaMenu · HH:mm` are managed.
- Never write, move, rename, or delete files under `~/.codex/automations`.
- Never adopt or modify any task whose complete name does not exactly match `CodexQuotaMenu · HH:mm`; sharing the prefix alone is insufficient.
- Managed tasks are daily standalone cron, local projectless, `gpt-5.6-luna`, reasoning `low`, and failures-only notifications.
- The activation prompt prohibits file reads, tool calls, and unrelated work.
- Show “已同步” / “Synced” only after local read-only verification.
- Keep the five-second usage refresh independent.
- Add no third-party runtime dependency; preserve macOS 14.
- Do not create a PR, push, tag, publish, delete existing tasks, or alter real automation files.

## File Map

- Create `ActivationSchedule.swift` for validated values and the fixed managed-task policy.
- Create `ActivationScheduleStore.swift` for corruption-safe preferences.
- Create `CodexAutomationReader.swift` for read-only discovery and minimal TOML field extraction.
- Create `AutomationReconciler.swift` for pure comparison.
- Create `SyncPromptBuilder.swift` for deterministic prompt generation.
- Create `ActivationScheduleSettingsModel.swift` for testable mutations and status.
- Create `ActivationScheduleWindowController.swift` for AppKit UI and platform adapters.
- Modify `AppDelegate.swift` and `Localization.swift` for integration.
- Add mirrored XCTest files and update Chinese/English usage and privacy documents.

---

### Task 1: Activation model and local persistence

**Files:**
- Create: `Sources/CodexQuotaMenu/ActivationSchedule.swift`
- Create: `Sources/CodexQuotaMenu/ActivationScheduleStore.swift`
- Create: `Tests/CodexQuotaMenuTests/ActivationScheduleTests.swift`
- Create: `Tests/CodexQuotaMenuTests/ActivationScheduleStoreTests.swift`

**Interfaces:**
- Produces `ActivationTime(hour:minute:)`, `displayValue`, and ordering.
- Produces `ActivationScheduleEntry(id:time:isEnabled:)` and `normalized(_:)`.
- Produces `ManagedAutomationPolicy` constants.
- Produces `ActivationScheduleStore.load()` and `save(_:)`.

- [ ] **Step 1: Write failing value tests**

```swift
func testTimeValidationFormattingSortingAndDuplicates() throws {
    let six = try ActivationTime(hour: 6, minute: 0)
    let eleven = try ActivationTime(hour: 11, minute: 2)
    XCTAssertEqual(six.displayValue, "06:00")
    XCTAssertEqual([eleven, six].sorted(), [six, eleven])
    XCTAssertThrowsError(try ActivationTime(hour: 24, minute: 0))
    let entry = ActivationScheduleEntry(time: six)
    XCTAssertThrowsError(try ActivationScheduleEntry.normalized([entry, entry]))
}
```

- [ ] **Step 2: Verify the red test**

Run: `swift test --filter ActivationScheduleTests`

Expected: FAIL because the types do not exist.

- [ ] **Step 3: Implement the value types**

```swift
enum ActivationScheduleError: Error, Equatable {
    case invalidTime
    case duplicateTime(ActivationTime)
    case corruptStoredData
}

struct ActivationTime: Codable, Hashable, Comparable, Sendable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw ActivationScheduleError.invalidTime
        }
        self.hour = hour
        self.minute = minute
    }

    var displayValue: String { String(format: "%02d:%02d", hour, minute) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            hour: values.decode(Int.self, forKey: .hour),
            minute: values.decode(Int.self, forKey: .minute)
        )
    }
}

struct ActivationScheduleEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var time: ActivationTime
    var isEnabled: Bool

    init(id: UUID = UUID(), time: ActivationTime, isEnabled: Bool = true) {
        self.id = id
        self.time = time
        self.isEnabled = isEnabled
    }

    static func normalized(_ entries: [Self]) throws -> [Self] {
        var seen = Set<ActivationTime>()
        for entry in entries where !seen.insert(entry.time).inserted {
            throw ActivationScheduleError.duplicateTime(entry.time)
        }
        return entries.sorted { $0.time < $1.time }
    }
}

enum ManagedAutomationPolicy {
    static let namePrefix = "CodexQuotaMenu · "
    static let model = "gpt-5.6-luna"
    static let reasoningEffort = "low"
    static let notificationPolicy = "failed_runs_only"
    static let activationPrompt = "这是定时激活请求。只回复“已激活”，不要读取文件、调用工具或执行其他操作。"
    static func name(for time: ActivationTime) -> String {
        namePrefix + time.displayValue
    }
}
```

- [ ] **Step 4: Write failing store tests**

```swift
func testStoreStartsEmptyAndRoundTripsSortedEntries() throws {
    let suite = "ScheduleStore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ActivationScheduleStore(defaults: defaults)
    XCTAssertEqual(try store.load(), [])
    let later = ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 2))
    let earlier = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 0))
    try store.save([later, earlier])
    XCTAssertEqual(try store.load(), [earlier, later])
}

func testCorruptDataThrowsWithoutBeingOverwritten() {
    let suite = "ScheduleStore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(Data("bad".utf8), forKey: ActivationScheduleStore.storageKey)
    XCTAssertThrowsError(try ActivationScheduleStore(defaults: defaults).load())
    XCTAssertNotNil(defaults.data(forKey: ActivationScheduleStore.storageKey))
}
```

- [ ] **Step 5: Implement persistence**

```swift
struct ActivationScheduleStore {
    static let storageKey = "activationSchedule.entries.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> [ActivationScheduleEntry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        guard let value = try? JSONDecoder().decode([ActivationScheduleEntry].self, from: data),
              let normalized = try? ActivationScheduleEntry.normalized(value) else {
            throw ActivationScheduleError.corruptStoredData
        }
        return normalized
    }

    func save(_ entries: [ActivationScheduleEntry]) throws {
        defaults.set(
            try JSONEncoder().encode(ActivationScheduleEntry.normalized(entries)),
            forKey: Self.storageKey
        )
    }
}
```

- [ ] **Step 6: Verify and commit**

Run: `swift test --filter 'ActivationSchedule(Tests|StoreTests)'`

Expected: PASS.

```bash
git add Sources/CodexQuotaMenu/ActivationSchedule.swift Sources/CodexQuotaMenu/ActivationScheduleStore.swift Tests/CodexQuotaMenuTests/ActivationScheduleTests.swift Tests/CodexQuotaMenuTests/ActivationScheduleStoreTests.swift
git commit -m "feat: store activation schedule preferences"
```

---

### Task 2: Read-only automation discovery

**Files:**
- Create: `Sources/CodexQuotaMenu/CodexAutomationReader.swift`
- Create: `Tests/CodexQuotaMenuTests/CodexAutomationReaderTests.swift`

**Interfaces:**
- Produces `CodexAutomation` with ID, version, kind, name, prompt, status, RRULE, model, reasoning, notification, execution environment, and target type.
- Produces `AutomationReadResult.available` and `.unavailable`.
- Produces `CodexAutomationReader(rootURL:fileManager:)` and `readManagedAutomations()`.

- [ ] **Step 1: Write failing directory/parser tests**

```swift
func testReadsOnlyManagedVersionOneTasks() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeAutomation(root, id: "managed", name: "CodexQuotaMenu · 06:00", version: 1)
    try writeAutomation(root, id: "other", name: "Personal reminder", version: 1)
    guard case .available(let tasks) =
            CodexAutomationReader(rootURL: root).readManagedAutomations() else {
        return XCTFail("expected available")
    }
    XCTAssertEqual(tasks.map(\.name), ["CodexQuotaMenu · 06:00"])
}

func testMissingDirectoryIsEmptyButUnknownManagedVersionIsUnavailable() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    XCTAssertEqual(CodexAutomationReader(rootURL: missing).readManagedAutomations(), .available([]))
    let root = temporaryRoot()
    try writeAutomation(root, id: "future", name: "CodexQuotaMenu · 06:00", version: 2)
    guard case .unavailable =
            CodexAutomationReader(rootURL: root).readManagedAutomations() else {
        return XCTFail("expected unavailable")
    }
}
```

The fixture writes complete one-line TOML fields, including `target = { type = "projectless" }`, only inside a unique temporary directory.

- [ ] **Step 2: Verify the red test**

Run: `swift test --filter CodexAutomationReaderTests`

Expected: FAIL because reader types do not exist.

- [ ] **Step 3: Implement safe scanning**

```swift
struct CodexAutomation: Equatable, Sendable {
    let id: String
    let version: Int
    let kind: String
    let name: String
    let prompt: String?
    let status: String
    let rrule: String
    let model: String?
    let reasoningEffort: String?
    let notificationPolicy: String?
    let executionEnvironment: String?
    let targetType: String?
}

enum AutomationReadResult: Equatable, Sendable {
    case available([CodexAutomation])
    case unavailable(String)
}

struct CodexAutomationReader {
    let rootURL: URL
    let fileManager: FileManager

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/automations", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func readManagedAutomations() -> AutomationReadResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return .available([])
        }
        guard isDirectory.boolValue,
              let children = try? fileManager.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else {
            return .unavailable("automation directory is unreadable")
        }
        var tasks: [CodexAutomation] = []
        for child in children.sorted(by: { $0.path < $1.path }) {
            let file = child.appendingPathComponent("automation.toml")
            guard let source = try? String(contentsOf: file, encoding: .utf8) else {
                return .unavailable("an automation file is unreadable")
            }
            guard let fields = try? StringFieldMap(source: source),
                  let name = fields.string("name") else {
                return .unavailable("an automation file has an ambiguous format")
            }
            guard ManagedAutomationPolicy.managedTime(from: name) != nil
                    || ManagedAutomationPolicy.isMalformedPrefixedName(name) else { continue }
            guard let parsed = Self.parse(fields), parsed.version == 1 else {
                return .unavailable("managed automation has an unsupported format")
            }
            tasks.append(parsed)
        }
        return .available(tasks.sorted { $0.name < $1.name })
    }
}
```

In the same file, implement `parse(_:)` and private `StringFieldMap`. Split on the first `=`, accept integers and one-line quoted strings, unescape quote/backslash sequences, and extract `type` from the inline target table. Do not interpret arbitrary TOML. Missing required fields (`version`, `id`, `kind`, `name`, `status`, `rrule`) returns `nil`.

- [ ] **Step 4: Add malformed-file safety coverage**

```swift
func testMalformedUnmanagedFileIsIgnoredButMalformedManagedFileBlocksVerification() throws {
    let root = temporaryRoot()
    try Data("not toml".utf8).write(to: automationFile(root, "other"))
    XCTAssertEqual(CodexAutomationReader(rootURL: root).readManagedAutomations(), .available([]))
    try Data("name = \"CodexQuotaMenu · 06:00\"".utf8).write(to: automationFile(root, "managed"))
    guard case .unavailable =
            CodexAutomationReader(rootURL: root).readManagedAutomations() else {
        return XCTFail("expected unavailable")
    }
}
```

- [ ] **Step 5: Verify and commit**

Run: `swift test --filter CodexAutomationReaderTests`

Expected: PASS without reading the real automation directory.

```bash
git add Sources/CodexQuotaMenu/CodexAutomationReader.swift Tests/CodexQuotaMenuTests/CodexAutomationReaderTests.swift
git commit -m "feat: read managed Codex automations safely"
```

---

### Task 3: Reconciliation and prompt generation

**Files:**
- Create: `Sources/CodexQuotaMenu/AutomationReconciler.swift`
- Create: `Sources/CodexQuotaMenu/SyncPromptBuilder.swift`
- Create: `Tests/CodexQuotaMenuTests/AutomationReconcilerTests.swift`
- Create: `Tests/CodexQuotaMenuTests/SyncPromptBuilderTests.swift`

**Interfaces:**
- Produces `AutomationDifference` arrays: missing, extra, duplicate, paused, misconfigured.
- Produces `AutomationSyncState`: unconfigured, synced, pending, unavailable.
- Produces `AutomationReconciler.evaluate(entries:readResult:timeZoneIdentifier:)`.
- Produces `SyncPromptBuilder.build(entries:timeZoneIdentifier:)`.

- [ ] **Step 1: Write failing reconciliation tests**

```swift
func testExactTaskIsSyncedAndEmptyIsUnconfigured() throws {
    let time = try ActivationTime(hour: 6, minute: 0)
    XCTAssertEqual(
        AutomationReconciler.evaluate(
            entries: [], readResult: .available([]), timeZoneIdentifier: "Asia/Shanghai"
        ),
        .unconfigured
    )
    XCTAssertEqual(
        AutomationReconciler.evaluate(
            entries: [.init(time: time)],
            readResult: .available([fixture(time)]),
            timeZoneIdentifier: "Asia/Shanghai"
        ),
        .synced
    )
}

func testReportsMissingExtraDuplicatePausedAndMisconfigured() throws {
    let six = try ActivationTime(hour: 6, minute: 0)
    let eleven = try ActivationTime(hour: 11, minute: 2)
    let extra = try ActivationTime(hour: 15, minute: 30)
    let state = AutomationReconciler.evaluate(
        entries: [.init(time: six), .init(time: eleven)],
        readResult: .available([
            fixture(six, status: "PAUSED"),
            fixture(six, model: "gpt-5.6-sol"),
            fixture(extra)
        ]),
        timeZoneIdentifier: "Asia/Shanghai"
    )
    guard case .pending(let difference) = state else { return XCTFail("expected pending") }
    XCTAssertEqual(difference.missing, [eleven])
    XCTAssertEqual(difference.extra, [extra])
    XCTAssertEqual(difference.duplicate, [six])
    XCTAssertEqual(difference.paused, [six])
    XCTAssertEqual(difference.misconfigured, [six])
}
```

- [ ] **Step 2: Verify the red reconciliation test**

Run: `swift test --filter AutomationReconcilerTests`

Expected: FAIL because reconciliation types do not exist.

- [ ] **Step 3: Implement pure reconciliation**

```swift
struct AutomationDifference: Equatable, Sendable {
    var missing: [ActivationTime] = []
    var extra: [ActivationTime] = []
    var duplicate: [ActivationTime] = []
    var paused: [ActivationTime] = []
    var misconfigured: [ActivationTime] = []
    var isEmpty: Bool {
        missing.isEmpty && extra.isEmpty && duplicate.isEmpty
            && paused.isEmpty && misconfigured.isEmpty
    }
}

enum AutomationSyncState: Equatable, Sendable {
    case unconfigured
    case synced
    case pending(AutomationDifference)
    case unavailable(String)
}

enum AutomationReconciler {
    static func evaluate(
        entries: [ActivationScheduleEntry],
        readResult: AutomationReadResult,
        timeZoneIdentifier: String
    ) -> AutomationSyncState {
        guard case .available(let tasks) = readResult else {
            if case .unavailable(let reason) = readResult { return .unavailable(reason) }
            return .unavailable("automation state is unavailable")
        }
        let desired = Set(entries.filter(\.isEnabled).map(\.time))
        let grouped = Dictionary(grouping: tasks, by: managedTime)
        let actual = Set(grouped.keys.compactMap { $0 })
        var difference = AutomationDifference()
        difference.missing = desired.subtracting(actual).sorted()
        difference.extra = actual.subtracting(desired).sorted()
        difference.duplicate = grouped.compactMap { time, values in
            time.flatMap { values.count > 1 ? $0 : nil }
        }.sorted()
        difference.paused = uniqueSorted(tasks.compactMap {
            guard let time = managedTime($0), $0.status != "ACTIVE" else { return nil }
            return time
        })
        difference.misconfigured = uniqueSorted(tasks.compactMap {
            guard let time = managedTime($0), desired.contains(time) else { return nil }
            return matchesPolicy($0, time, timeZoneIdentifier) ? nil : time
        })
        if desired.isEmpty && tasks.isEmpty { return .unconfigured }
        return difference.isEmpty ? .synced : .pending(difference)
    }
}
```

Implement anchored managed-name parsing, semicolon RRULE parsing with case-insensitive `TZID`, exact daily hour/minute matching, and fixed-policy checks for kind, name, prompt, status, model, reasoning, notification, local execution, and projectless target. Deduplicate/sort all difference arrays. Disabled local entries are excluded from desired state; unavailable reads never become synced.

- [ ] **Step 4: Write failing prompt tests**

```swift
func testPromptIsSortedScopedAndUsesFixedConfiguration() throws {
    let entries = [
        ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 2)),
        ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 0)),
        ActivationScheduleEntry(time: try ActivationTime(hour: 7, minute: 30), isEnabled: false)
    ]
    let prompt = try SyncPromptBuilder.build(entries: entries, timeZoneIdentifier: "Asia/Shanghai")
    XCTAssertLessThan(
        prompt.range(of: "CodexQuotaMenu · 06:00")!.lowerBound,
        prompt.range(of: "CodexQuotaMenu · 11:02")!.lowerBound
    )
    XCTAssertFalse(prompt.contains("CodexQuotaMenu · 07:30"))
    XCTAssertTrue(prompt.contains("failed_runs_only"))
    XCTAssertTrue(prompt.contains("不要修改任何其他计划任务"))
}

func testEmptyPromptDeletesManagedTasksOnly() throws {
    let prompt = try SyncPromptBuilder.build(entries: [], timeZoneIdentifier: "Asia/Shanghai")
    XCTAssertTrue(prompt.contains("期望时间列表为空"))
    XCTAssertTrue(prompt.contains("仅删除完整名称严格匹配"))
    XCTAssertFalse(prompt.contains("6点激活 Codex 用量窗口"))
}
```

- [ ] **Step 5: Implement deterministic prompt generation**

```swift
enum SyncPromptBuilder {
    static func build(
        entries: [ActivationScheduleEntry],
        timeZoneIdentifier: String
    ) throws -> String {
        let enabled = try ActivationScheduleEntry.normalized(entries).filter(\.isEnabled)
        let lines = enabled.map {
            "- \(ManagedAutomationPolicy.name(for: $0.time))：每天 \($0.time.displayValue)"
        }
        let desired = lines.isEmpty
            ? "期望时间列表为空；仅删除完整名称严格匹配“\(ManagedAutomationPolicy.exactNameFormat)”的受管任务。"
            : (["期望任务："] + lines).joined(separator: "\n")
        return """
        请使用 Codex 官方计划任务功能完成一次幂等对账。
        只管理完整名称严格匹配“\(ManagedAutomationPolicy.exactNameFormat)”的计划任务；仅共享前缀的名称保持不变，不得删除、修改或合并。不要修改任何其他计划任务。
        \(desired)
        每个期望时间必须恰好有一个独立的 standalone cron 任务，时区为 \(timeZoneIdentifier)，执行环境为 local，目标为 projectless，模型为 \(ManagedAutomationPolicy.model)，推理强度为 \(ManagedAutomationPolicy.reasoningEffort)，通知策略为 \(ManagedAutomationPolicy.notificationPolicy)。任务提示词必须精确为：\(ManagedAutomationPolicy.activationPrompt)
        创建缺少的任务，修正不一致配置，删除期望列表之外的受管任务，并合并重复受管任务。完成后简短列出结果；不要修改任何其他计划任务。
        """
    }
}
```

- [ ] **Step 6: Verify and commit**

Run: `swift test --filter 'AutomationReconcilerTests|SyncPromptBuilderTests'`

Expected: PASS.

```bash
git add Sources/CodexQuotaMenu/AutomationReconciler.swift Sources/CodexQuotaMenu/SyncPromptBuilder.swift Tests/CodexQuotaMenuTests/AutomationReconcilerTests.swift Tests/CodexQuotaMenuTests/SyncPromptBuilderTests.swift
git commit -m "feat: reconcile and describe activation tasks"
```

---

### Task 4: Testable settings model

**Files:**
- Create: `Sources/CodexQuotaMenu/ActivationScheduleSettingsModel.swift`
- Create: `Tests/CodexQuotaMenuTests/ActivationScheduleSettingsModelTests.swift`

**Interfaces:**
- Consumes store, reader closure, reconciler, and prompt builder.
- Produces `entries`, `syncState`, `loadError`, `load`, `add`, `update`, `remove`, `refreshActualState`, and `makeSyncPrompt`.

- [ ] **Step 1: Write failing model tests**

```swift
@MainActor
func testMutationsPersistSortAndPreserveOnDuplicate() throws {
    let suite = "SettingsModel.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = ActivationScheduleStore(defaults: defaults)
    let model = ActivationScheduleSettingsModel(
        store: store,
        readAutomations: { .available([]) }
    )
    model.load()
    try model.add(time: ActivationTime(hour: 11, minute: 2))
    try model.add(time: ActivationTime(hour: 6, minute: 0))
    XCTAssertEqual(model.entries.map(\.time.displayValue), ["06:00", "11:02"])
    XCTAssertThrowsError(try model.add(time: ActivationTime(hour: 6, minute: 0)))
    XCTAssertEqual(try store.load().count, 2)
}

@MainActor
func testUnavailableReaderCannotReportSynced() {
    let model = ActivationScheduleSettingsModel(
        store: ActivationScheduleStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
        readAutomations: { .unavailable("unsupported") }
    )
    model.load(timeZoneIdentifier: "Asia/Shanghai")
    XCTAssertEqual(model.syncState, .unavailable("unsupported"))
}
```

- [ ] **Step 2: Verify the red test**

Run: `swift test --filter ActivationScheduleSettingsModelTests`

Expected: FAIL because the settings model does not exist.

- [ ] **Step 3: Implement the model**

```swift
@MainActor
final class ActivationScheduleSettingsModel {
    private let store: ActivationScheduleStore
    private let readAutomations: () -> AutomationReadResult
    private(set) var entries: [ActivationScheduleEntry] = []
    private(set) var syncState: AutomationSyncState = .unconfigured
    private(set) var loadError: Error?

    init(
        store: ActivationScheduleStore = ActivationScheduleStore(),
        readAutomations: @escaping () -> AutomationReadResult = {
            CodexAutomationReader().readManagedAutomations()
        }
    ) {
        self.store = store
        self.readAutomations = readAutomations
    }

    func load(timeZoneIdentifier: String = TimeZone.current.identifier) {
        do {
            entries = try store.load()
            loadError = nil
            refreshActualState(timeZoneIdentifier: timeZoneIdentifier)
        } catch {
            loadError = error
            syncState = .unavailable("stored schedule is unreadable")
        }
    }

    func add(time: ActivationTime) throws {
        try persist(entries + [ActivationScheduleEntry(time: time)])
    }

    func update(id: UUID, time: ActivationTime, isEnabled: Bool) throws {
        var value = entries
        guard let index = value.firstIndex(where: { $0.id == id }) else { return }
        value[index].time = time
        value[index].isEnabled = isEnabled
        try persist(value)
    }

    func remove(id: UUID) throws {
        try persist(entries.filter { $0.id != id })
    }

    func refreshActualState(timeZoneIdentifier: String = TimeZone.current.identifier) {
        syncState = AutomationReconciler.evaluate(
            entries: entries,
            readResult: readAutomations(),
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    func makeSyncPrompt(timeZoneIdentifier: String = TimeZone.current.identifier) throws -> String {
        try SyncPromptBuilder.build(entries: entries, timeZoneIdentifier: timeZoneIdentifier)
    }

    private func persist(_ value: [ActivationScheduleEntry]) throws {
        let normalized = try ActivationScheduleEntry.normalized(value)
        try store.save(normalized)
        entries = normalized
        refreshActualState()
    }
}
```

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter ActivationScheduleSettingsModelTests`

Expected: PASS.

```bash
git add Sources/CodexQuotaMenu/ActivationScheduleSettingsModel.swift Tests/CodexQuotaMenuTests/ActivationScheduleSettingsModelTests.swift
git commit -m "feat: add activation schedule settings state"
```

---

### Task 5: Localized AppKit window and menu integration

**Files:**
- Create: `Sources/CodexQuotaMenu/ActivationScheduleWindowController.swift`
- Modify: `Sources/CodexQuotaMenu/Localization.swift`
- Modify: `Sources/CodexQuotaMenu/AppDelegate.swift`
- Modify: `Tests/CodexQuotaMenuTests/LocalizationTests.swift`
- Create: `Tests/CodexQuotaMenuTests/ActivationScheduleWindowControllerTests.swift`

**Interfaces:**
- Produces `ActivationScheduleWindowController(model:textProvider:pasteboardWriter:urlOpener:)`.
- Produces `showWindowAndRefresh()`, `updateLanguage()`, and testable `performSync`.
- Adds menu action `openActivationScheduleSettings()`.

- [ ] **Step 1: Add failing localization tests**

```swift
func testActivationScheduleStringsAreLocalized() {
    let zh = AppText(language: .simplifiedChinese)
    let en = AppText(language: .english)
    XCTAssertEqual(zh.activationScheduleAction, "激活时间设置…")
    XCTAssertEqual(en.activationScheduleAction, "Activation Times…")
    XCTAssertEqual(zh.syncToCodexAction, "同步到 Codex")
    XCTAssertEqual(en.activationSyncedStatus, "Synced")
}
```

- [ ] **Step 2: Add localized copy**

Add Chinese/English properties for window title, heading, add, delete, enabled, refresh, sync, unconfigured, synced, pending, unavailable, prompt copied, Codex-open failure, duplicate-time error, and difference labels. Follow the existing `AppText` computed-property pattern.

- [ ] **Step 3: Write the failing injected sync test**

```swift
@MainActor
func testSyncCopiesPromptAndOpensNewThreadWithoutClaimingSynced() throws {
    var copied: String?
    var opened: URL?
    let model = ActivationScheduleSettingsModel(
        store: ActivationScheduleStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
        readAutomations: { .available([]) }
    )
    model.load()
    try model.add(time: ActivationTime(hour: 6, minute: 0))
    let controller = ActivationScheduleWindowController(
        model: model,
        textProvider: { AppText(language: .simplifiedChinese) },
        pasteboardWriter: { copied = $0; return true },
        urlOpener: { opened = $0; return true }
    )
    XCTAssertTrue(controller.performSync(timeZoneIdentifier: "Asia/Shanghai"))
    XCTAssertTrue(copied?.contains("CodexQuotaMenu · 06:00") == true)
    XCTAssertEqual(opened?.absoluteString, "codex://threads/new")
    XCTAssertNotEqual(model.syncState, .synced)
}
```

- [ ] **Step 4: Implement the window**

```swift
@MainActor
final class ActivationScheduleWindowController: NSWindowController, NSWindowDelegate {
    typealias PasteboardWriter = (String) -> Bool
    typealias URLOpener = (URL) -> Bool
    private let model: ActivationScheduleSettingsModel
    private let textProvider: () -> AppText
    private let pasteboardWriter: PasteboardWriter
    private let urlOpener: URLOpener
    private var refreshTimer: Timer?

    init(
        model: ActivationScheduleSettingsModel,
        textProvider: @escaping () -> AppText,
        pasteboardWriter: @escaping PasteboardWriter = Self.writePasteboard,
        urlOpener: @escaping URLOpener = { NSWorkspace.shared.open($0) }
    ) {
        self.model = model
        self.textProvider = textProvider
        self.pasteboardWriter = pasteboardWriter
        self.urlOpener = urlOpener
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.center()
        buildViewHierarchy()
        render()
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult
    func performSync(timeZoneIdentifier: String = TimeZone.current.identifier) -> Bool {
        guard let prompt = try? model.makeSyncPrompt(timeZoneIdentifier: timeZoneIdentifier),
              pasteboardWriter(prompt),
              let url = URL(string: "codex://threads/new") else { return false }
        let opened = urlOpener(url)
        renderCopyResult(openedCodex: opened)
        return opened
    }
}
```

Use an `NSScrollView` with vertical `NSStackView`. Every row has a checkbox, `NSDatePicker` restricted to hour/minute, and delete button, with entry UUID in `representedObject`. Mutations persist through the model and rerender. Add add/refresh/sync buttons and render every difference category. Keep sync enabled for a valid empty list, but disable it for corrupt stored data.

Poll every ten seconds only while visible:

```swift
private func startRefreshTimer() {
    refreshTimer?.invalidate()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
        self?.model.refreshActualState()
        self?.render()
    }
}

func windowWillClose(_ notification: Notification) {
    refreshTimer?.invalidate()
    refreshTimer = nil
}

private static func writePasteboard(_ value: String) -> Bool {
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(value, forType: .string)
}
```

- [ ] **Step 5: Wire one reusable window into `AppDelegate`**

```swift
private let activationScheduleModel = ActivationScheduleSettingsModel()
private lazy var activationScheduleWindowController = ActivationScheduleWindowController(
    model: activationScheduleModel,
    textProvider: { [weak self] in self?.text ?? AppText.current }
)

@objc private func openActivationScheduleSettings() {
    activationScheduleWindowController.showWindowAndRefresh()
}
```

Insert “激活时间设置…” before Language with Command-comma. On language selection call `updateLanguage()`. On termination close the window before stopping other services. Do not connect this reader to `CodexClient` or its five-second timer.

- [ ] **Step 6: Verify and commit**

Run: `swift test --filter 'LocalizationTests|ActivationScheduleWindowControllerTests'`

Run: `swift test`

Expected: PASS; tests use injected pasteboard/opener and temporary preferences.

```bash
git add Sources/CodexQuotaMenu/ActivationScheduleWindowController.swift Sources/CodexQuotaMenu/Localization.swift Sources/CodexQuotaMenu/AppDelegate.swift Tests/CodexQuotaMenuTests/LocalizationTests.swift Tests/CodexQuotaMenuTests/ActivationScheduleWindowControllerTests.swift
git commit -m "feat: add activation schedule settings window"
```

---

### Task 6: Documentation and end-to-end verification

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`
- Modify: `docs/product-and-usage.md`
- Modify: `docs/product-and-usage.en.md`
- Modify: `PRIVACY.md`
- Modify: `PRIVACY.en.md`

**Interfaces:**
- Documents exact-format name ownership, the one-confirmation flow, read-only local access, and inability to prove an individual run.

- [ ] **Step 1: Update Chinese and English usage**

Add and translate:

```text
打开“激活时间设置…”，添加每天需要的时间，然后点击“同步到 Codex”。
应用会复制一条完整对账指令并打开 Codex；粘贴并发送一次。
任务创建后，窗口通过本机只读检测自动显示“已同步”。
只有修改时间时才需再次同步；退出 CodexQuotaMenu 不影响后台任务。
```

Document empty-first-launch, empty-list cleanup of exact-format managed tasks only, silent success, and no adoption of names that merely share the prefix.

- [ ] **Step 2: Update privacy and limitations**

Add and translate:

```text
应用只读扫描 ~/.codex/automations/*/automation.toml，仅提取对账所需配置。
应用不会写入这些文件、不读取计划任务运行对话，也不上传计划任务配置。
本地检测只能确认配置一致，不能证明某次后台运行成功。
```

- [ ] **Step 3: Verify terminology**

Run:

```bash
rg -n "CodexQuotaMenu ·|激活时间设置|Activation Times|automation.toml|不能证明|cannot prove" README.md README.en.md docs/product-and-usage.md docs/product-and-usage.en.md PRIVACY.md PRIVACY.en.md
git diff --check
```

Expected: all six documents contain matching workflow/privacy statements and `git diff --check` is silent.

- [ ] **Step 4: Run final automated verification**

```bash
swift test
swift build -c release
./build-app.sh
codesign --verify --deep --strict dist/Codex用量.app
dist/Codex用量.app/Contents/MacOS/CodexQuotaMenu --check
```

Expected: tests, Release build, signature, and connection check PASS. If Codex is unavailable, report that check separately. No automated test writes real automation files.

- [ ] **Step 5: Perform bounded manual UI verification**

Without sending the copied prompt:

1. Open one reusable settings window.
2. Confirm a clean preference domain starts empty.
3. Exercise add, edit, disable, delete, sort, and duplicate validation.
4. Confirm clicking sync alone never shows “已同步.”
5. Confirm the prompt is copied and a new Codex thread opens.
6. Cancel without sending and verify no real automation file changed.
7. Confirm the existing five-second usage refresh remains responsive.

- [ ] **Step 6: Commit docs and record evidence**

```bash
git add README.md README.en.md docs/product-and-usage.md docs/product-and-usage.en.md PRIVACY.md PRIVACY.en.md
git commit -m "docs: explain activation schedule workflow"
git status --short --branch
git log --oneline --max-count=10
```

Expected: clean worktree and local commits visible. Do not push, tag, publish, or delete the user's existing tasks.
