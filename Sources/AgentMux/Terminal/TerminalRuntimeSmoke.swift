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
        checkSurfaceLifecycle(controller)
        print("Terminal runtime verified both palettes and 24 surface teardown cycles")
        exit(0)
    }

    /// Reproduce the lifecycle involved in the 2026-11-27 hang: a live
    /// surface receives display-change callbacks and is then destroyed. The
    /// old engine could wait forever in CVDisplayLinkStop from
    /// ghostty_surface_free; the resource checker runs this process with a
    /// timeout so any recurrence fails the build.
    private static func checkSurfaceLifecycle(_ controller: TerminalController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        for index in 0..<24 {
            weak var releasedView: AppTerminalView?
            weak var releasedSurface: TerminalSurface?
            autoreleasepool {
                let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
                let state = TerminalViewState(controller: controller)
                let options = TerminalSurfaceOptions(backend: .inMemory(session))
                state.configuration = options

                let view = AppTerminalView(frame: window.contentRect(forFrameRect: window.frame))
                view.delegate = state
                view.controller = controller
                view.configuration = options
                window.contentView = view
                guard state.surface != nil else { fail("Surface cycle \(index) did not attach") }
                releasedView = view
                releasedSurface = state.surface

                session.receive("surface cycle \(index)\r\n")
                guard session.waitForPendingOutput() else {
                    fail("Surface cycle \(index) did not drain its output")
                }
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification,
                    object: NSApp
                )
                NotificationCenter.default.post(
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                )
                window.contentView = nil
            }

            // Deliver the display-change follow-up queued by the view. It has
            // a weak receiver and must not keep the old surface alive.
            for _ in 0..<3 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
            }
            guard releasedView == nil, releasedSurface == nil else {
                fail("Surface cycle \(index) did not release its renderer")
            }
        }
        window.close()
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
