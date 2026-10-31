import AgentMuxCore
import SwiftUI

/// Which list the palette shows.
enum PaletteMode {
    /// ⌘K: jump to an agent, or message it.
    case agents
    /// ⇧⌘P: every command, with its key.
    case commands
}

/// The palette overlay. ⌘K is a fuzzy agent switcher with an optional
/// message composer: Return jumps to the highlighted agent; typing in the
/// composer and pressing Return (or ⌘↩ from the search field) sends that
/// text to the agent. ⇧⌘P lists the commands; a leading ">" in the search
/// field switches to them, as in editors.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let mode: PaletteMode

    @State private var query = ""
    @State private var message = ""
    @State private var selected = 0
    @State private var status: String?
    @State private var sending = false
    @FocusState private var focus: Field?

    private enum Field { case search, compose }

    /// Listing commands. A ">" typed first switches to them, as in editors;
    /// Delete in an empty field goes back to agents. The ">" is not kept in
    /// the field: the field selects its text when focused, so a prefilled
    /// ">" was replaced by the first key typed.
    @State private var showsCommands = false

    /// The panel is opaque, in the window's own color, as Xcode's Open
    /// Quickly is: a material blends with what is behind it inside the
    /// window, and over a dark terminal in light mode it turned gray, with
    /// gray text on it. RootView adds the dimmed backdrop and the motion.
    var body: some View {
        palette
            .frame(width: 600)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            .onAppear { reset(mode) }
            .onChange(of: mode) { _, new in reset(new) }
            .onChange(of: query) { _, new in
                if !showsCommands, new.hasPrefix(">") {
                    showsCommands = true
                    query = String(new.dropFirst())
                }
                selected = 0
            }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
            Divider()
            if !showsCommands { composer }
            footer
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: showsCommands ? "command" : "magnifyingglass").foregroundStyle(.secondary)
            TextField(showsCommands ? "Run a command…" : "Jump to an agent…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focus, equals: .search)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.return) {
                    if showsCommands {
                        run()
                    } else if NSEvent.modifierFlags.contains(.command) {
                        sendMessage()
                    } else {
                        jump()
                    }
                    return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(.delete) {
                    guard showsCommands, query.isEmpty else { return .ignored }
                    showsCommands = false
                    return .handled
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if showsCommands {
                        if commands.isEmpty { emptyRow("No matches.") }
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            CommandRow(command: command, highlighted: index == selected)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = index; run() }
                        }
                    } else {
                        if filtered.isEmpty { emptyRow(query.isEmpty ? "No agents." : "No matches.") }
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, agent in
                            PaletteRow(agent: agent, highlighted: index == selected)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = index; jump() }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)
            .animation(Motion.quick, value: showsCommands)
            // Rows keep their own ids (an index id on a row replaced its
            // identity, and the lazy list reused stale rows as the list
            // changed); scrolling goes to the highlighted row's id.
            .onChange(of: selected) { _, new in
                let id: AnyHashable? = showsCommands
                    ? (commands.indices.contains(new) ? AnyHashable(commands[new].id) : nil)
                    : (filtered.indices.contains(new) ? AnyHashable(filtered[new].id) : nil)
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane").foregroundStyle(.secondary)
            TextField(composePrompt, text: $message)
                .textFieldStyle(.plain)
                .focused($focus, equals: .compose)
                .onKeyPress(.return) { sendMessage(); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .disabled(highlightedAgent == nil)
            if sending { ProgressView().controlSize(.small).transition(.opacity) }
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(HoverButtonStyle(keepsColor: true))
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(Motion.quick, value: sending)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let status {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning).lineLimit(1)
            } else if showsCommands {
                hint("↑↓", "navigate"); hint("↩", "run"); hint("esc", "close")
            } else {
                hint("↑↓", "navigate"); hint("↩", "open"); hint("tab", "message"); hint(">", "commands"); hint("esc", "close")
            }
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.medium).padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(text)
        }
    }

    // MARK: Data

    private var terms: [Substring] {
        query.lowercased().split(separator: " ")
    }

    private var filtered: [AgentEntry] {
        let terms = terms
        guard !terms.isEmpty else { return model.allAgentEntries }
        return model.allAgentEntries.filter { agent in
            let hay = "\(agent.title) \(agent.kind.label) \(agent.configLabel) \(agent.session) \(agent.space.path) \(agent.device.name) \(agent.device.server)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private var commands: [AppCommand] {
        let terms = terms
        return AppCommand.allCases.filter { command in
            guard command.isAvailable(model) else { return false }
            let title = command.title(model).lowercased()
            return terms.allSatisfy { title.contains($0) }
        }
    }

    private var highlightedAgent: AgentEntry? {
        filtered.indices.contains(selected) ? filtered[selected] : nil
    }

    private var composePrompt: String {
        if let agent = highlightedAgent { return "Message \(model.customName(agent.identityKey) ?? agent.title)…" }
        return "Message the selected agent…"
    }

    private var canSend: Bool {
        !sending && highlightedAgent != nil && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Actions

    private func reset(_ mode: PaletteMode) {
        showsCommands = mode == .commands
        query = ""
        selected = 0
        status = nil
        focus = .search
    }

    private func move(_ delta: Int) {
        let count = showsCommands ? commands.count : filtered.count
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func jump() {
        guard let agent = highlightedAgent else { return }
        model.select(agent.ref)
        close()
    }

    private func run() {
        guard commands.indices.contains(selected) else { return }
        let command = commands[selected]
        close()
        CommandRunner(model: model, openWindow: openWindow, openSettings: openSettings).perform(command)
    }

    private func sendMessage() {
        guard canSend, let agent = highlightedAgent else { return }
        let text = message
        sending = true
        status = nil
        Task {
            let error = await model.sendPrompt(agent.ref, text)
            sending = false
            if let error { status = error } else { close() }
        }
    }

    private func close() {
        model.palette = nil
    }
}

/// The highlighted row as menus and Spotlight mark it: the accent color
/// with white text, inset in a rounded rectangle.
/// The pointer over another row gives it a light wash, without moving the
/// highlight: the list can scroll under a resting pointer.
private struct PaletteHighlight: ViewModifier {
    let on: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(on ? Color.accentColor : Color.primary.opacity(hovering ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .padding(.horizontal, 6)
    }
}

private struct CommandRow: View {
    @Environment(AppModel.self) private var model
    let command: AppCommand
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(command.title(model)).lineLimit(1)
            Spacer(minLength: 6)
            if let shortcut = command.shortcut {
                Text(shortcut.symbols)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(PaletteHighlight(on: highlighted))
    }
}

private struct PaletteRow: View {
    @Environment(AppModel.self) private var model
    let agent: AgentEntry
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            brandIcon.frame(width: 18)
            TwoLineRow {
                Text(model.customName(agent.identityKey) ?? agent.title)
            } detail: {
                Text("\(agent.configLabel) · \(agent.device.name) · \(agent.spaceLabel)")
            } time: {
                ActivityTime(entry: agent)
            } status: {
                AgentStatusGlyph(activity: agent.activity, fault: agent.fault, retrying: agent.isRetrying,
                                 done: agent.isDone, plain: highlighted)
            }
        }
        .modifier(PaletteHighlight(on: highlighted))
    }

    @ViewBuilder private var brandIcon: some View {
        if let resource = BrandIconLoader.agentIcon(for: agent.kind) {
            BrandIcon(resource: resource, size: 15)
        } else {
            Image(systemName: "terminal")
        }
    }
}
