import Foundation

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
            ? "期望时间列表为空；删除全部受管任务。仅删除名称完整且严格匹配“\(ManagedAutomationPolicy.exactNameFormat)”的任务。"
            : (["期望任务："] + lines).joined(separator: "\n")

        return """
        请使用 Codex 官方计划任务功能完成一次幂等对账。
        \(ManagedAutomationPolicy.promptOwnershipRule)
        \(desired)
        每个期望时间必须恰好有一个独立的 standalone cron 任务，状态必须为 ACTIVE（启用），时区为 \(timeZoneIdentifier)，执行环境为 local，目标为 projectless，模型为 \(ManagedAutomationPolicy.model)，推理强度为 \(ManagedAutomationPolicy.reasoningEffort)，通知策略为 \(ManagedAutomationPolicy.notificationPolicy)。任务提示词必须精确为：\(ManagedAutomationPolicy.activationPrompt)
        创建缺少的任务，修正不一致配置，将暂停任务恢复为 ACTIVE（启用），仅删除期望列表之外且名称完整匹配上述格式的受管任务，并合并名称完整匹配上述格式的重复受管任务。完成后简短列出结果；不要修改任何其他计划任务。
        """
    }
}
