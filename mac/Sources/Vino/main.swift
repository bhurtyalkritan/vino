import AppKit
import VinoCore

// `Vino run setup.exe` and friends act as the command-line tool; a plain launch opens the app.
if let status = CLI.runIfCommand(CommandLine.arguments) { exit(status) }
// for screenshots: VINO_APPEARANCE=light, set before any window exists
if ProcessInfo.processInfo.environment["VINO_APPEARANCE"] == "light" { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
VinoApp.main()
