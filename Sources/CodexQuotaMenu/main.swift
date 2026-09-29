import AppKit

if CommandLine.arguments.dropFirst().first == ManagedModelConfig.helperFlag {
    exit(ManagedModelConfig.runHelper(arguments: CommandLine.arguments))
}
if CommandLine.arguments.contains("--check-default-model") {
    do {
        let state = try DefaultModelSettingsService().load()
        let output: [String: Any] = ["userModel": state.user.model, "userEffort": state.user.effort,
            "effectiveModel": state.effective.model, "effectiveEffort": state.effective.effort,
            "managedOverride": state.hasManagedOverride, "availableModels": state.models.map(\.id)]
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
        exit(0)
    } catch { fputs("Default model check failed: \(error.localizedDescription)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--activate") {
    exit(ActivationRunner.run(arguments: Array(CommandLine.arguments.dropFirst())))
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
