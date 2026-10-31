import AgentMuxCore
import AppKit
import SwiftUI

/// Every action the app offers by name. The menus take their keys from here
/// and the command palette lists the actions with those keys, so the two
/// can't disagree.
enum AppCommand: String, CaseIterable, Identifiable {
    case goToAgent
    case commandPalette
    case dashboard
    case nextAgent
    case previousAgent
    case zoom
    case files
    case newTerminal
    case openInWindow
    case redraw
    case closeView
    case pin
    case rename
    case continueNow
    case cancelContinue
    case notifications
    case markAllRead
    case clearDone
    case sessions
    case accounts
    case refresh
    case toggleSidebar
    case resources
    case groupByContainer
    case groupByProject
    case groupBySession
    case groupByStatus
    case showAll
    case showActive
    case showAttention
    case settings
    case checkForUpdates

    var id: String { rawValue }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .goToAgent: KeyboardShortcut("k", modifiers: .command)
        case .commandPalette: KeyboardShortcut("p", modifiers: [.command, .shift])
        case .dashboard: KeyboardShortcut("0", modifiers: .command)
        case .nextAgent: KeyboardShortcut("]", modifiers: .command)
        case .previousAgent: KeyboardShortcut("[", modifiers: .command)
        case .zoom: KeyboardShortcut(.return, modifiers: [.command, .shift])
        case .files: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .newTerminal: KeyboardShortcut("t", modifiers: .command)
        case .notifications: KeyboardShortcut("n", modifiers: [.command, .option])
        case .sessions: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .refresh: KeyboardShortcut("r", modifiers: .command)
        // Bound by SidebarCommands and the Settings scene, not by us.
        case .toggleSidebar: KeyboardShortcut("s", modifiers: [.command, .control])
        case .settings: KeyboardShortcut(",", modifiers: .command)
        default: nil
        }
    }

    var systemImage: String {
        switch self {
        case .goToAgent: "arrow.right.circle"
        case .commandPalette: "command"
        case .dashboard: "square.grid.2x2"
        case .nextAgent: "chevron.down"
        case .previousAgent: "chevron.up"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .files: "folder"
        case .newTerminal: "terminal"
        case .openInWindow: "macwindow.on.rectangle"
        case .redraw: "arrow.triangle.2.circlepath"
        case .closeView: "xmark.circle"
        case .pin: "pin"
        case .rename: "pencil"
        case .continueNow: "play.circle"
        case .cancelContinue: "stop.circle"
        case .notifications: "bell"
        case .markAllRead: "envelope.open"
        case .clearDone: "checkmark.circle"
        case .sessions: "rectangle.split.3x1"
        case .accounts: "person.2"
        case .refresh: "arrow.clockwise"
        case .toggleSidebar: "sidebar.left"
        case .resources: "sidebar.right"
        case .groupByContainer: GroupBy.container.systemImage
        case .groupByProject: GroupBy.project.systemImage
        case .groupBySession: GroupBy.session.systemImage
        case .groupByStatus: GroupBy.status.systemImage
        case .showAll: AgentFilter.all.systemImage
        case .showActive: AgentFilter.active.systemImage
        case .showAttention: AgentFilter.attention.systemImage
        case .settings: "gearshape"
        case .checkForUpdates: "arrow.down.circle"
        }
    }

    @MainActor func title(_ model: AppModel) -> String {
        switch self {
        case .goToAgent: "Go to Agent"
        case .commandPalette: "Command Palette"
        case .dashboard: "Dashboard"
        case .nextAgent: "Next Agent"
        case .previousAgent: "Previous Agent"
        case .zoom: model.isZoomed ? "Show All Agents" : "Zoom Agent"
        case .files: "Files"
        case .newTerminal: "New Terminal"
        case .openInWindow: "Open in New Window"
        case .redraw: "Redraw"
        case .closeView: "Close View"
        case .pin: model.selectedAgent.map { model.isPinned($0.identityKey) } == true ? "Unpin Agent" : "Pin Agent"
        case .rename: "Rename Agent"
        case .continueNow: "Continue Now"
        case .cancelContinue: "Cancel Auto-continue"
        case .notifications: "Notifications"
        case .markAllRead: "Mark All Notifications as Read"
        case .clearDone: "Clear Done Marks"
        case .sessions: "Sessions"
        case .accounts: "Accounts"
        case .refresh: "Refresh"
        case .toggleSidebar: "Toggle Sidebar"
        case .resources: model.inspectorVisible ? "Hide Resources" : "Show Resources"
        case .groupByContainer: "Group by Container"
        case .groupByProject: "Group by Project"
        case .groupBySession: "Group by Session"
        case .groupByStatus: "Group by Status"
        case .showAll: "Show All Agents"
        case .showActive: "Show Active Agents"
        case .showAttention: "Show Agents That Need Attention"
        case .settings: "Settings"
        case .checkForUpdates: "Check for Updates"
        }
    }

    /// Whether the command does anything now; the palette lists only these.
    @MainActor func isAvailable(_ model: AppModel) -> Bool {
        let selection = model.selection
        switch self {
        case .commandPalette: return false
        case .zoom: return model.isTiled
        case .files: return model.selectedFilesSpec != nil
        case .newTerminal, .closeView: return selection != nil
        case .openInWindow:
            return selection.map { model.terminal(for: $0) != nil && !model.poppedOut.contains($0) } ?? false
        case .redraw: return selection.map { model.terminal(for: $0) != nil } ?? false
        case .pin, .rename: return model.selectedAgent != nil
        case .continueNow, .cancelContinue: return selection.map { model.pendingNudges[$0] != nil } ?? false
        case .markAllRead: return model.inbox.unreadCount > 0
        case .clearDone: return !model.inbox.unreadFinished.isEmpty
        case .groupByContainer: return SidebarPreferences.grouping != .container
        case .groupByProject: return SidebarPreferences.grouping != .project
        case .groupBySession: return SidebarPreferences.grouping != .session
        case .groupByStatus: return SidebarPreferences.grouping != .status
        case .showAll: return SidebarPreferences.filter != .all
        case .showActive: return SidebarPreferences.filter != .active
        case .showAttention: return SidebarPreferences.filter != .attention
        case .checkForUpdates: return UpdateChecker.current != nil
        default: return true
        }
    }
}

/// Runs commands with the window actions they need.
@MainActor
struct CommandRunner {
    let model: AppModel
    let openWindow: OpenWindowAction
    let openSettings: OpenSettingsAction

    func perform(_ command: AppCommand) {
        let selection = model.selection
        switch command {
        case .goToAgent: model.palette = .agents
        case .commandPalette: model.palette = .commands
        case .dashboard: model.selection = nil
        case .nextAgent: model.selectAdjacentAgent(1)
        case .previousAgent: model.selectAdjacentAgent(-1)
        case .zoom: model.toggleZoom()
        case .files: if let spec = model.selectedFilesSpec { openWindow(value: spec) }
        case .newTerminal: if let spec = model.newTerminalSpec() { openWindow(value: spec) }
        case .openInWindow:
            if let selection {
                model.popOut(selection)
                openWindow(value: selection)
            }
        case .redraw: if let selection { model.terminal(for: selection)?.resync() }
        case .closeView: if let selection { model.closeView(selection) }
        case .pin: if let agent = model.selectedAgent { model.togglePin(agent.identityKey) }
        case .rename: model.renaming = model.selectedAgent
        case .continueNow: if let selection { model.sendNudgeNow(selection) }
        case .cancelContinue: if let selection { model.cancelNudge(selection) }
        case .notifications: model.showInbox = true
        case .markAllRead: model.markAllInboxRead()
        case .clearDone: model.markAllDoneSeen()
        case .sessions:
            model.containerTab = .sessions
            openWindow(id: "sessions")
        case .accounts:
            model.containerTab = .accounts
            openWindow(id: "sessions")
        case .refresh: model.refreshAll()
        case .toggleSidebar: NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        case .resources: model.toggleInspector()
        case .groupByContainer: SidebarPreferences.grouping = .container
        case .groupByProject: SidebarPreferences.grouping = .project
        case .groupBySession: SidebarPreferences.grouping = .session
        case .groupByStatus: SidebarPreferences.grouping = .status
        case .showAll: SidebarPreferences.filter = .all
        case .showActive: SidebarPreferences.filter = .active
        case .showAttention: SidebarPreferences.filter = .attention
        case .settings: openSettings()
        case .checkForUpdates: model.checkForUpdates()
        }
    }
}

/// The sidebar's view options, kept in user defaults (the sidebar reads them
/// with `@AppStorage`, so a change from the palette shows at once).
enum SidebarPreferences {
    static let groupingKey = "sidebarGroupBy"
    static let filterKey = "sidebarFilter"

    static var grouping: GroupBy {
        get { GroupBy(rawValue: UserDefaults.standard.string(forKey: groupingKey) ?? "") ?? .project }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: groupingKey) }
    }

    static var filter: AgentFilter {
        get { AgentFilter(rawValue: UserDefaults.standard.string(forKey: filterKey) ?? "") ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: filterKey) }
    }
}

extension KeyboardShortcut {
    /// As menus show it: "⇧⌘F".
    var symbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .return: text += "↩"
        case .escape: text += "⎋"
        case .delete: text += "⌫"
        case .tab: text += "⇥"
        case .space: text += "Space"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        default: text += String(key.character).uppercased()
        }
        return text
    }
}

extension KeyboardShortcut {
    /// The same key in Ghostty's keybind syntax: "super+shift+p".
    var ghosttyTrigger: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("super") }
        switch key {
        case .return: parts.append("enter")
        case .escape: parts.append("escape")
        case .delete: parts.append("backspace")
        case .tab: parts.append("tab")
        case .space: parts.append("space")
        case .upArrow: parts.append("arrow_up")
        case .downArrow: parts.append("arrow_down")
        case .leftArrow: parts.append("arrow_left")
        case .rightArrow: parts.append("arrow_right")
        default: parts.append(String(key.character).lowercased())
        }
        return parts.joined(separator: "+")
    }
}

extension View {
    /// The command's key, if it has one.
    @ViewBuilder func shortcut(_ command: AppCommand) -> some View {
        if let shortcut = command.shortcut { keyboardShortcut(shortcut) } else { self }
    }
}
