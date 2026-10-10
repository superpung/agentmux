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

    /// Quitting releases this app's own tmux clients and connections, and
    /// nothing else. Gives up after a few seconds so an unreachable host
    /// cannot block quitting; leftovers are released on the next connect.
    ///
    /// The release runs off the main actor and the reply goes through the
    /// main run loop, because AppKit waits for the reply in a nested event
    /// loop that may be running inside a main-actor job.
    @MainActor
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.stopPolling()
        let remotes = model.detachAllForQuit()
        guard !remotes.isEmpty else { return .terminateNow }
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withTaskGroup(of: Void.self) { closes in
                        for remote in remotes {
                            closes.addTask { _ = await remote.close() }
                        }
                    }
                }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            AppDelegate.performOnMainRunLoop { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
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
