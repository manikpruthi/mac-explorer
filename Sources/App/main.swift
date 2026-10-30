import AppKit

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.regular)
application.run()
