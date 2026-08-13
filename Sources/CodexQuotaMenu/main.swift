import AppKit

if ProcessInfo.processInfo.arguments.contains("--check") {
    ConnectionCheck.run()
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.run()
