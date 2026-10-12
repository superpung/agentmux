import AppKit
import SwiftUI
import UserNotifications

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
                    model.requestNotificationAuthorization()
                    Task { await model.discoverAll() }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Next Agent") { model.selectAdjacentAgent(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous Agent") { model.selectAdjacentAgent(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
            }
        }

        WindowGroup(for: PaneRef.self) { $ref in
            if let ref {
                PoppedTerminalWindow(ref: ref)
                    .environment(model)
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .defaultSize(width: 900, height: 600)

        Window("Sessions", id: "sessions") {
            SessionsWindow()
                .environment(model)
                .frame(minWidth: 460, minHeight: 360)
        }
        .defaultSize(width: 620, height: 640)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var model: AppModel?

    func applicationDidFinishLaunching(_: Notification) {
        // Needed when launched as a bare executable rather than from a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Show the banner even when AgentMux is frontmost (the finished agent is
    /// never the one being viewed — that case is filtered before posting).
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Quitting closes this app's own control clients. Each kills its grouped
    /// session; closing the app's pipes ends the ssh clients, and
    /// `destroy-unattached` removes any grouped session whose kill did not
    /// land. The user's sessions and their window sizes are untouched (the
    /// forced size was soft), so there is nothing to wait for.
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
