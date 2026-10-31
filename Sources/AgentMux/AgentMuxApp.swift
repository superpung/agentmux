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
                    model.inbox.refreshBadge()
                    model.startPolling()
                    model.requestNotificationAuthorization()
                    model.startUpdateChecks()
                    Task { await model.discoverAll() }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates() }
            }
            // Nothing here prints, and ⇧⌘P is the command palette.
            CommandGroup(replacing: .printItem) {}
            SidebarCommands()
            // Edit ▸ Find (⌘F, ⌘G, ⇧⌘G, ⌘E) for the Files previews. Items stay
            // disabled where no responder handles them, so a focused terminal
            // still receives these keys.
            TextEditingCommands()
            CommandGroup(after: .toolbar) {
                Button("Go to Agent") { model.palette = .agents }
                    .shortcut(.goToAgent)
                Button("Command Palette") { model.palette = .commands }
                    .shortcut(.commandPalette)
                Button("Dashboard") { model.selection = nil }
                    .shortcut(.dashboard)
                OpenSessionsButton(model: model)
                OpenAccountsButton(model: model)
                NewTerminalButton(model: model)
                Button("Refresh") { model.refreshAll() }
                    .shortcut(.refresh)
                Button("Next Agent") { model.selectAdjacentAgent(1) }
                    .shortcut(.nextAgent)
                Button("Previous Agent") { model.selectAdjacentAgent(-1) }
                    .shortcut(.previousAgent)
                // With several agents shown (⌘-click in the sidebar), the
                // focused one fills the area until toggled back.
                Button(AppCommand.zoom.title(model)) { model.toggleZoom() }
                    .shortcut(.zoom)
                    .disabled(!model.isTiled)
                Button("Notifications") { model.showInbox = true }
                    .shortcut(.notifications)
                Divider()
                OpenFilesButton(model: model)
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

        WindowGroup(for: EphemeralTerminalSpec.self) { $spec in
            if let spec {
                EphemeralTerminalWindow(spec: spec)
                    .environment(model)
                    .frame(minWidth: 480, minHeight: 300)
            }
        }
        .defaultSize(width: 820, height: 520)

        Window("Sessions", id: "sessions") {
            ContainerWindow()
                .environment(model)
                .frame(minWidth: 480, minHeight: 380)
        }
        .defaultSize(width: 640, height: 640)

        WindowGroup("Files", for: FilesWindowSpec.self) { $spec in
            if let spec {
                FileBrowserWindow(spec: spec)
                    .environment(model)
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .defaultSize(width: 1000, height: 680)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Menu command that opens the combined container window on the Sessions tab
/// (the only place tmux sessions are created or killed).
private struct OpenSessionsButton: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Button("Sessions") {
            model.containerTab = .sessions
            openWindow(id: "sessions")
        }
        .shortcut(.sessions)
    }
}

/// Opens the combined container window on the Accounts tab (read-only map of
/// which Claude accounts share a project's sessions, and so can be switched).
private struct OpenAccountsButton: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Button("Accounts") {
            model.containerTab = .accounts
            openWindow(id: "sessions")
        }
    }
}

/// Opens a throwaway shell (not in tmux) in the selected agent's container.
private struct NewTerminalButton: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Button("New Terminal") {
            if let spec = model.newTerminalSpec() { openWindow(value: spec) }
        }
        .shortcut(.newTerminal)
        .disabled(model.selection == nil)
    }
}

/// Opens the Files window for the selected agent's folder (or brings it
/// forward); it then stays on that folder whatever is selected next.
private struct OpenFilesButton: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Button("Files") { if let spec = model.selectedFilesSpec { openWindow(value: spec) } }
            .shortcut(.files)
            .disabled(model.selectedFilesSpec == nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var model: AppModel?
    /// For callbacks that arrive off the main actor and must not capture it.
    @MainActor static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_: Notification) {
        MainActor.assumeIsolated { AppDelegate.shared = self }
        // Needed when launched as a bare executable rather than from a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        MainActor.assumeIsolated { model?.inbox.refreshBadge() }
    }

    /// Clicking a banner opens its agent and marks the inbox item read, or
    /// opens the release page of an update.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let link = info[Notifier.releaseURLKey] as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        let raw = info[Notifier.inboxIDKey] as? String
        if let raw, let id = UUID(uuidString: raw) {
            AppDelegate.performOnMainRunLoop {
                NSApp.activate(ignoringOtherApps: true)
                AppDelegate.shared?.model?.openInboxItem(id)
            }
        }
        completionHandler()
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
