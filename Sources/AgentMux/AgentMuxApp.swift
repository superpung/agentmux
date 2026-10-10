import AppKit
import SwiftUI

@main
struct AgentMuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("AgentMux", id: "main") {
            RootView()
                .environment(model)
                .onAppear {
                    appDelegate.model = model
                    model.startPolling()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh All") { model.refreshAll() }
                    .keyboardShortcut("r", modifiers: [.command])
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
        scheduleSnapshotIfRequested()
    }

    /// AGENTMUX_SNAPSHOT=<png path>: after the first refreshes, render the
    /// window's content into a PNG and quit (layout checks without a
    /// screen-recording permission; Metal and blur layers come out blank).
    private func scheduleSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["AGENTMUX_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            AppDelegate.performOnMainRunLoop { NSApp.terminate(nil) }
        }
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
