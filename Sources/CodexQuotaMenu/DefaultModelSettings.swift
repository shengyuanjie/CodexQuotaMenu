import Foundation

struct CodexModelOption: Equatable {
    let id: String
    let name: String
    let efforts: [String]
    let defaultEffort: String
    var supportsFast: Bool = true
}

struct DefaultModelSelection: Equatable {
    let model: String
    let effort: String
    var serviceTier: String = "default"
    var fastEnabled: Bool { ["fast", "priority"].contains(serviceTier) }

    func validate() throws {
        guard !model.isEmpty, model.count < 150,
              model.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort),
              ["default", "fast", "priority"].contains(serviceTier) else {
            throw DefaultModelError.invalidSelection
        }
    }
}

struct DefaultModelSnapshot {
    let user: DefaultModelSelection
    let managedModel: String?
    let managedEffort: String?
    let profile: String?
    let models: [CodexModelOption]
    var managedServiceTier: String? = nil
    var effective: DefaultModelSelection {
        DefaultModelSelection(model: managedModel ?? user.model, effort: managedEffort ?? user.effort,
                              serviceTier: managedServiceTier ?? user.serviceTier)
    }
    var hasManagedOverride: Bool { managedModel != nil || managedEffort != nil || managedServiceTier != nil }
}

enum DefaultModelError: LocalizedError {
    case invalidSelection, invalidResponse, unsupportedSystemFile, managedElsewhere, activeProfile
    case concurrentChange, administratorCancelled, administratorFailed, verificationFailed
    var errorDescription: String? {
        let zh = AppText.current.language == .simplifiedChinese
        switch self {
        case .invalidSelection: return zh ? "请选择可用的模型和推理强度。" : "Select an available model and reasoning effort."
        case .invalidResponse: return zh ? "Codex 返回的配置或模型列表不完整，请更新 Codex 后重试。" : "Codex returned incomplete configuration or model data. Update Codex and retry."
        case .unsupportedSystemFile: return zh ? "系统配置格式无法安全修改，请手动检查 /etc/codex/requirements.toml。" : "The system configuration cannot be safely edited. Check /etc/codex/requirements.toml manually."
        case .managedElsewhere: return zh ? "默认值来自其他托管配置，无法由本机应用覆盖，请联系配置管理员。" : "Defaults are supplied by another managed configuration. Contact its administrator."
        case .activeProfile: return zh ? "当前启用了 Codex 配置方案。请先切回默认配置，再修改全局默认模型。" : "A Codex profile is active. Switch to the default configuration before editing global defaults."
        case .concurrentChange: return zh ? "配置已被其他程序修改，请刷新后重试。" : "Configuration changed in another process. Refresh and retry."
        case .administratorCancelled: return zh ? "已取消管理员验证，未修改系统默认值。" : "Administrator authentication was cancelled. System defaults were not changed."
        case .administratorFailed: return zh ? "管理员操作失败。请刷新检查实际默认值后重试。" : "Administrator operation failed. Refresh to check actual defaults before retrying."
        case .verificationFailed: return zh ? "保存后的实际默认值与选择不一致，可能存在其他覆盖配置。请刷新检查。" : "Verified defaults differ from the selection. Another configuration may override them. Refresh to inspect."
        }
    }
}

protocol DefaultModelRPC {
    func modelRequest(_ method: String, params: [String: Any]) throws -> [String: Any]
}

extension CodexClient: DefaultModelRPC {}

struct DefaultModelSettingsService {
    var makeClient: () -> any DefaultModelRPC = { CodexClient() }
    var readSystemFile: () throws -> String = { try String(contentsOfFile: ManagedModelConfig.filePath, encoding: .utf8) }
    var writeSystemFile: (String, DefaultModelSelection) throws -> Void = ManagedModelConfig.authorizeAndWrite

    func load() throws -> DefaultModelSnapshot {
        let client = makeClient()
        let configResult = try client.modelRequest("config/read", params: ["includeLayers": false])
        let requirementResult = try client.modelRequest("configRequirements/read", params: [:])
        guard let config = configResult["config"] as? [String: Any] else { throw DefaultModelError.invalidResponse }
        let managed = ((requirementResult["requirements"] as? [String: Any])?["models"] as? [String: Any])?["newThread"] as? [String: Any]
        var options: [CodexModelOption] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var params: [String: Any] = ["includeHidden": false, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try client.modelRequest("model/list", params: params)
            guard let rows = result["data"] as? [[String: Any]] else { throw DefaultModelError.invalidResponse }
            for row in rows {
                guard let id = row["model"] as? String,
                      let efforts = row["supportedReasoningEfforts"] as? [[String: Any]] else { continue }
                let supported = efforts.compactMap { $0["reasoningEffort"] as? String }
                    .filter { (try? DefaultModelSelection(model: id, effort: $0).validate()) != nil }
                guard !supported.isEmpty, !options.contains(where: { $0.id == id }) else { continue }
                options.append(CodexModelOption(id: id, name: row["displayName"] as? String ?? id,
                    efforts: supported, defaultEffort: row["defaultReasoningEffort"] as? String ?? supported[0],
                    supportsFast: Self.supportsFast(row)))
            }
            cursor = result["nextCursor"] as? String
            if let cursor, !seenCursors.insert(cursor).inserted { throw DefaultModelError.invalidResponse }
        } while cursor != nil
        guard !options.isEmpty else { throw DefaultModelError.invalidResponse }
        return DefaultModelSnapshot(user: .init(model: config["model"] as? String ?? "", effort: config["model_reasoning_effort"] as? String ?? "",
                serviceTier: config["service_tier"] as? String ?? "default"),
            managedModel: managed?["model"] as? String, managedEffort: managed?["modelReasoningEffort"] as? String,
            profile: config["profile"] as? String, models: options, managedServiceTier: managed?["serviceTier"] as? String)
    }

    private static func supportsFast(_ row: [String: Any]) -> Bool {
        if let tiers = row["serviceTiers"] as? [[String: Any]], !tiers.isEmpty {
            return tiers.contains { ["fast", "priority"].contains($0["id"] as? String ?? "") }
        }
        if let tiers = row["additionalSpeedTiers"] as? [String] {
            return tiers.contains { ["fast", "priority"].contains($0) }
        }
        // Older backends do not advertise speed tiers. Saving is still verified by readback.
        return true
    }

    func save(_ selection: DefaultModelSelection) throws -> DefaultModelSnapshot {
        try selection.validate()
        let current = try load()
        guard current.profile == nil else { throw DefaultModelError.activeProfile }
        guard current.models.contains(where: { $0.id == selection.model && $0.efforts.contains(selection.effort) && (!selection.fastEnabled || $0.supportsFast) }) else {
            throw DefaultModelError.invalidSelection
        }
        if current.hasManagedOverride {
            guard let source = try? readSystemFile(),
                  let local = try? ManagedModelConfig.values(in: source),
                  local.model == current.managedModel, local.effort == current.managedEffort,
                  local.serviceTier == current.managedServiceTier else {
                throw DefaultModelError.managedElsewhere
            }
            // Validate the exact edit before asking macOS for administrator authentication.
            _ = try ManagedModelConfig.replacing(source, with: selection)
            if local.model != selection.model || local.effort != selection.effort ||
                (local.serviceTier != nil && local.serviceTier != selection.serviceTier) {
                try writeSystemFile(source, selection)
            }
        }
        do {
            _ = try makeClient().modelRequest("config/batchWrite", params: [
                "edits": [
                    ["keyPath": "model", "value": selection.model, "mergeStrategy": "upsert"],
                    ["keyPath": "model_reasoning_effort", "value": selection.effort, "mergeStrategy": "upsert"],
                    ["keyPath": "service_tier", "value": selection.serviceTier, "mergeStrategy": "upsert"]
                ], "reloadUserConfig": true
            ])
            // A fresh backend also reloads system requirements, not just the user config.
            let verified = try load()
            guard verified.effective == selection, verified.user == selection else { throw DefaultModelError.verificationFailed }
            return verified
        } catch {
            throw NSError(domain: "CodexQuotaMenu.DefaultModel", code: 1, userInfo: [NSLocalizedDescriptionKey:
                (AppText.current.language == .simplifiedChinese
                    ? "未能完整保存或核验；部分配置可能已更新。请刷新检查。\n"
                    : "Saving or verification did not finish; some settings may have changed. Refresh to inspect.\n") + error.localizedDescription])
        }
    }
}
