import AppKit
import Darwin
import Foundation
import GhosttyTerminal

/// Exercises the packaged runtime in a disposable process, before settings,
/// polling or remote terminals are opened.
@MainActor
enum TerminalRuntimeSmoke {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["AGENTMUX_TERMINAL_SMOKE_TEST"] == "1" else { return }
        _ = NSApplication.shared
        let marker = "AGENTMUX_TERMINAL_SMOKE_MUTABLE"
        guard setenv(marker, "initial", 1) == 0 else { fail("Could not set the test environment") }
        let controller = GhosttyRuntime.controller

        // Reallocate the live environment table and replace an existing
        // string after Ghostty has initialized. Appearance changes reread the
        // runtime's environment while finalizing a fresh config.
        for index in 0..<512 {
            guard setenv("AGENTMUX_TERMINAL_SMOKE_\(index)", "value", 1) == 0 else {
                fail("Could not grow the test environment")
            }
            if index.isMultiple(of: 32) {
                let dark = !index.isMultiple(of: 64)
                checkPalette(controller, dark: dark)
            }
        }
        guard setenv(marker, String(repeating: "changed", count: 128), 1) == 0 else {
            fail("Could not replace a test environment entry")
        }
        for index in 0..<512 {
            guard unsetenv("AGENTMUX_TERMINAL_SMOKE_\(index)") == 0 else {
                fail("Could not shrink the test environment")
            }
        }
        checkPalette(controller, dark: false)
        checkPalette(controller, dark: true)
        print("Terminal runtime verified both palettes after environment changes")
        exit(0)
    }

    private static func checkPalette(_ controller: TerminalController, dark: Bool) {
        controller.setColorScheme(dark ? .dark : .light)
        let expected = dark ? TerminalColor(red: 0x10, green: 0x10, blue: 0x12)
            : TerminalColor(red: 0xFF, green: 0xFF, blue: 0xFF)
        guard controller.lastConfigurationIssue == nil, controller.backgroundColor == expected else {
            fail("Terminal could not apply the \(dark ? "dark" : "light") palette")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
