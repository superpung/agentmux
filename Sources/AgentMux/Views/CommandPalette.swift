import AgentMuxCore
import SwiftUI

/// ⌘K overlay: a fuzzy agent switcher with an optional message composer.
/// Return jumps to the highlighted agent; typing in the composer and pressing
/// Return (or ⌘↩ from the search field) sends that text to the agent.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var message = ""
    @State private var selected = 0
    @State private var status: String?
    @State private var sending = false
    @FocusState private var focus: Field?

    private enum Field { case search, compose }

    var body: some View {
        ZStack(alignment: .top) {
            // Dim + click-away to dismiss.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }

            palette
                .frame(width: 560)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
                .shadow(radius: 30, y: 10)
                .padding(.top, 90)
        }
        .onAppear { focus = .search; selected = 0 }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
            Divider()
            composer
            footer
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Jump to an agent…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focus, equals: .search)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.command) { sendMessage() } else { jump() }
                    return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text(query.isEmpty ? "No agents." : "No matches.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, agent in
                        PaletteRow(agent: agent, highlighted: index == selected)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = index; jump() }
                    }
                }
            }
            .frame(maxHeight: 300)
            .onChange(of: selected) { _, new in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) } }
        }
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
            } else {
                hint("↑↓", "navigate"); hint("↩", "open"); hint("tab", "message"); hint("esc", "close")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Text(key).fontWeight(.semibold).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 4))
            Text(text)
        }
    }

    // MARK: Data

    private var filtered: [AgentEntry] {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return model.allAgentEntries }
        return model.allAgentEntries.filter { agent in
            let hay = "\(agent.title) \(agent.kind.label) \(agent.configLabel) \(agent.session) \(agent.space.path) \(agent.device.name) \(agent.device.server)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
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

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selected = (selected + delta + filtered.count) % filtered.count
    }

    private func jump() {
        guard let agent = highlightedAgent else { return }
        model.select(agent.ref)
        close()
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
        isPresented = false
    }
}

private struct PaletteRow: View {
    @Environment(AppModel.self) private var model
    let agent: AgentEntry
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            brandIcon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.customName(agent.identityKey) ?? agent.title).lineLimit(1)
                Text("\(agent.configLabel) · \(agent.device.name) · \(agent.spaceLabel)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            AgentStatusGlyph(activity: agent.activity, retrying: agent.isRetrying)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(highlighted ? Theme.itemWashSelected : .clear)
        .overlay(alignment: .leading) {
            if highlighted { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
    }

    @ViewBuilder private var brandIcon: some View {
        if let resource = BrandIconLoader.agentIcon(for: agent.kind) {
            BrandIcon(resource: resource, size: 15)
        } else {
            Image(systemName: "terminal")
        }
    }
}
