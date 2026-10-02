import AppKit

if CommandLine.arguments.dropFirst().first == ManagedModelConfig.helperFlag {
    exit(ManagedModelConfig.runHelper(arguments: CommandLine.arguments))
}
if CommandLine.arguments.contains("--check-default-model") {
    do {
        let state = try DefaultModelSettingsService().load()
        let output: [String: Any] = ["userModel": state.user.model, "userEffort": state.user.effort,
            "effectiveModel": state.effective.model, "effectiveEffort": state.effective.effort,
            "userServiceTier": state.user.serviceTier, "effectiveServiceTier": state.effective.serviceTier,
            "fastEnabled": state.effective.fastEnabled, "managedOverride": state.hasManagedOverride, "availableModels": state.models.map(\.id)]
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
        exit(0)
    } catch { fputs("Default model check failed: \(error.localizedDescription)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--activate") {
    exit(ActivationRunner.run(arguments: Array(CommandLine.arguments.dropFirst())))
}
if CommandLine.arguments.dropFirst().first == "--send-scheduled-message" {
    guard CommandLine.arguments.count == 3, let id = UUID(uuidString: CommandLine.arguments[2]) else { exit(2) }
    exit(ScheduledMessageRunner().run(id: id))
}
if CommandLine.arguments.dropFirst().first == "--check-scheduled-message-target" {
    guard [4, 5].contains(CommandLine.arguments.count), let id = UUID(uuidString: CommandLine.arguments[2]) else { exit(2) }
    do {
        let runner = ScheduledMessageRunner()
        let target = try runner.resolveThread(id.uuidString.lowercased())
        let effort = try runner.resolveEffort(CommandLine.arguments[3], CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : nil, target.effort)
        let result = ["threadId": id.uuidString.lowercased(), "directory": target.directory.path,
                      "model": CommandLine.arguments[3], "effort": effort]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        exit(0)
    } catch { fputs("Scheduled message target check failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.dropFirst().first == "--check-scheduled-message-desktop" {
    guard CommandLine.arguments.count == 3, let id = UUID(uuidString: CommandLine.arguments[2]) else { exit(2) }
    do {
        let client = ScheduledMessageDesktopClient()
        guard try client.connect(), let owner = try client.owner(threadID: id.uuidString.lowercased()) else { exit(1) }
        let state = try client.snapshot(threadID: id.uuidString.lowercased(), owner: owner)
        print("Desktop target verified; busy=\(ScheduledMessageDesktopClient.isBusy(state))")
        exit(0)
    } catch { fputs("Desktop target check failed\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--sync-activation") {
    do {
        try ActivationLaunchAgentSynchronizer().synchronize(entries: ActivationScheduleStore().load())
        print("Activation schedules synchronized")
        exit(0)
    } catch {
        print("Activation synchronization failed: \(error)")
        exit(1)
    }
}

if ProcessInfo.processInfo.arguments.contains("--check") {
    ConnectionCheck.run()
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.run()
