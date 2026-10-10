import AppKit
import SwiftUI

@main
struct AgentMuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onAppear {
                    appDelegate.model = model
                    model.startPolling()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationDidFinishLaunching(_: Notification) {
        // Needed when launched as a bare executable rather than from a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Quitting ends this app's own control clients and nothing else: each
    /// one detaches when its input closes, which also happens if the app
    /// dies. Tagged leftovers are released on the next connect.
    @MainActor
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        model?.stopPolling()
        model?.closeAllTerminals()
        return .terminateNow
    }

    /// Runs `block` on the main thread from the run loop (in every common
    /// mode, including AppKit's modal modes), not as a main-queue job.
    nonisolated static func performOnMainRunLoop(_ block: @escaping @Sendable @MainActor () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { block() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
