import AgentMuxCore
import GhosttyTerminal
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var pendingSwitch: PendingSwitch?
    @State private var switchError: String?
    /// The tile arrangement in use, kept across window resizes unless another
    /// is clearly better (see `TileLayout.best`).
    @State private var arrangement: TileLayout.Arrangement?
    /// A tile being dragged by its header onto another, to swap places.
    @State private var drag: TileDrag?
    /// The layout the surfaces were last shown in. While the cards move to a
    /// new one, the surfaces wait hidden.
    @State private var settledLayout: String?

    /// A requested account switch awaiting confirmation (it stops and relaunches
    /// the agent, so it is confirmed first).
    private struct PendingSwitch: Identifiable {
        let ref: PaneRef
        let account: String
        var id: String { account }
        var label: String { (account as NSString).lastPathComponent }
    }

    /// The terminal palette, so the letterbox margins behind it match; the
    /// dashboard / empty state just follows the system.
    private var backgroundTheme: TerminalThemePreference {
        if let ref = model.selection, model.terminal(for: ref) != nil {
            return model.terminalTheme
        }
        return .system
    }

    var body: some View {
        ZStack {
            GhosttyRuntime.terminalBackground(for: backgroundTheme)
            GeometryReader { proxy in
                terminals(in: CGRect(origin: .zero, size: proxy.size))
            }
            if let ref = model.selection {
                if model.isTiled {
                    // Tiles draw their own placeholders.
                } else if model.poppedOut.contains(ref) {
                    PoppedInfoView()
                } else if model.terminal(for: ref) == nil {
                    PanePlaceholderView(ref: ref)
                }
            } else if model.configError != nil || model.hosts.isEmpty {
                EmptyStateView()
            } else {
                DashboardView()
            }
        }
        .animation(Motion.quick, value: model.selection)
        // "Connecting…" gives way to the terminal with a fade.
        .animation(Motion.quick, value: model.selection.map { model.terminal(for: $0) != nil })
        .navigationTitle(title)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.selection != nil { StatusBar() }
        }
        .alert(
            pendingSwitch.map { "Switch to \($0.label)?" } ?? "",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            presenting: pendingSwitch
        ) { pending in
            Button("Switch", role: .destructive) { performSwitch(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("The running agent will be stopped and relaunched under \(pending.label), resuming this conversation. Any in-progress turn is lost.")
        }
        .alert(
            "Couldn't switch account",
            isPresented: Binding(get: { switchError != nil }, set: { if !$0 { switchError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: { Text(switchError ?? "") }
    }

    /// Every open terminal stays mounted so its screen survives switching;
    /// only the ones on screen are visible and live. Each keeps one place in
    /// the view tree whether it fills the area, is a tile, or is hidden, so
    /// moving between those never rebuilds its surface. A hidden terminal
    /// keeps a full-area frame, or its tile's while another tile is zoomed,
    /// so hiding it does not resize its remote window. A mirror shown in its
    /// own window is not rendered here, so its single surface never lives in
    /// two hierarchies.
    ///
    /// Two layers, so the layout can move without resizing live terminals
    /// every frame (each resize reflows the terminal and its remote window):
    /// cards (frame, header, focus ring) animate to their new places, while
    /// each surface takes its final size at once, hidden, and fades in when
    /// the cards have settled.
    @ViewBuilder private func terminals(in area: CGRect) -> some View {
        let tiles = model.tiles
        let tiled = model.isTiled
        // Tiles are cards on the window's background, a gap apart and from
        // its edges; a zoomed tile is one card filling the same space.
        let inner = tiled ? area.insetBy(dx: Self.tileGap, dy: Self.tileGap) : area
        let current = TileLayout.best(count: tiles.count, in: inner.size, cell: GhosttyRuntime.approximateCellSize,
                                      chrome: TileCard.chromeHeight, gap: Self.tileGap, current: arrangement)
        let frames = Dictionary(uniqueKeysWithValues: zip(tiles, TileLayout.frames(current, in: inner, gap: Self.tileGap)))
        let shown = Set(model.visibleRefs)
        let zoomed = model.isZoomed
        let cardFrame = { (ref: PaneRef) in zoomed && shown.contains(ref) ? inner : frames[ref] ?? area }
        // A tile's surface sits in its card under the header; otherwise it
        // fills the area.
        let surfaceFrame = { (ref: PaneRef) in tiled && tiles.contains(ref) ? TileCard.content(of: cardFrame(ref)) : area }
        // The tiles' cards, or a bare card for the one agent shown alone, so
        // it can grow into a tile and back.
        let cards = (tiled ? tiles : model.selection.map { [$0] } ?? []).filter { !model.poppedOut.contains($0) }
        // What moves the cards: which tiles, zoom, and the arrangement. Not
        // the window's size, which resizes everything live as before.
        let layout = "\(tiles.map(\.paneID))|\(tiled)|\(zoomed)|\(current.axis)\(current.lines)"
        let settled = settledLayout == layout
        let header = { (ref: PaneRef) in
            TileHeader(ref: ref, onDrag: { location in
                drag = TileDrag(ref: ref, target: zoomed ? nil : frames.first { $0.value.contains(location) }?.key)
            }, onDrop: {
                if let drag, let target = drag.target { model.swapTiles(drag.ref, target) }
                drag = nil
            })
        }
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
                .opacity(tiled ? 1 : 0)
                .animation(Motion.panel, value: tiled)
            ZStack(alignment: .topLeading) {
                ForEach(cards, id: \.self) { ref in
                    let rect = tiled ? cardFrame(ref) : area
                    TileCardView(on: tiled, focused: model.selection == ref,
                                 placeholder: tiled && model.terminal(for: ref) == nil ? ref : nil,
                                 header: header(ref))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        // A tile behind a zoomed one keeps its place, unseen.
                        .opacity(!tiled || shown.contains(ref) ? 1 : 0)
                        .allowsHitTesting(!tiled || shown.contains(ref))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(Motion.panel, value: layout)
            ForEach(Array(model.terminals.values), id: \.ref) { terminal in
                if !model.poppedOut.contains(terminal.ref) {
                    let rect = surfaceFrame(terminal.ref)
                    let visible = shown.contains(terminal.ref)
                    MirroredSurfaceView(terminal: terminal)
                        .background(GhosttyRuntime.terminalBackground(for: model.terminalTheme))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        // Resizing a live surface every animation frame would
                        // reflow it (and its remote window) over and over.
                        .animation(nil, value: rect)
                        .opacity(visible && settled ? 1 : 0)
                        .allowsHitTesting(visible)
                }
            }
            // Where a dragged tile would go.
            if let target = drag?.target, target != drag?.ref, let rect = frames[target] {
                RoundedRectangle(cornerRadius: TileCard.radius)
                    .fill(Color.accentColor.opacity(0.18))
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: drag?.target)
        .coordinateSpace(.named(TileHeader.space))
        .onChange(of: current, initial: true) { _, new in arrangement = new }
        .task(id: layout) {
            // The first layout shows at once; a change waits for the cards.
            if settledLayout != nil {
                try? await Task.sleep(for: TileCard.settleDelay)
                guard !Task.isCancelled else { return }
            }
            withAnimation(Motion.quick) { settledLayout = layout }
        }
    }

    private static let tileGap: CGFloat = 6

    private struct TileDrag {
        var ref: PaneRef
        var target: PaneRef?
    }

    private func performSwitch(_ pending: PendingSwitch) {
        let ref = pending.ref
        let account = pending.account
        Task { if let error = await model.switchAccount(ref, to: account) { switchError = error } }
    }

    private var title: String {
        guard let ref = model.selection else { return "AgentMux" }
        if let agent = model.agentEntry(ref) { return agent.title }
        if let pane = model.paneEntry(ref) { return pane.title }
        return "AgentMux"
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if let ref = model.selection, let agent = model.agentEntry(ref), agent.activity != .unknown {
            ToolbarItem(placement: .navigation) {
                StatusChip(activity: agent.activity, showsIdle: true, retrying: agent.isRetrying, done: agent.isDone)
            }
        }
        if let ref = model.selection, let terminal = model.terminal(for: ref) {
            ToolbarItem {
                Menu {
                    if !model.poppedOut.contains(ref) {
                        Button {
                            model.popOut(ref)
                            openWindow(value: ref)
                        } label: {
                            Label("Open in New Window", systemImage: "macwindow.on.rectangle")
                        }
                    }
                    Button {
                        terminal.resync()
                    } label: {
                        Label("Redraw", systemImage: "arrow.triangle.2.circlepath")
                    }
                    let switchable = model.switchableAccounts(for: ref)
                    if !switchable.isEmpty {
                        Menu {
                            ForEach(switchable, id: \.self) { account in
                                Button((account as NSString).lastPathComponent) {
                                    pendingSwitch = PendingSwitch(ref: ref, account: account)
                                }
                            }
                        } label: {
                            Label("Switch Account", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(model.agentEntry(ref)?.activity == .working)
                    }
                    Divider()
                    Button {
                        model.closeView(ref)
                    } label: {
                        Label("Close View", systemImage: "xmark.circle")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("Open in a new window, redraw, or close this view")
            }
        }
    }
}

/// The Ghostty surface filling the detail pane. The terminal scales its font
/// so the whole remote grid fits, so the surface is never larger than this
/// area (a Metal layer ignores SwiftUI clipping, so it must not overflow).
private struct MirroredSurfaceView: View {
    let terminal: PaneTerminal

    var body: some View {
        // The surface fills the detail pane at a fixed font; its grid size
        // drives the remote window size (see PaneTerminal), so the pane
        // reflows to fill the view like a normal terminal.
        TerminalSurfaceView(context: terminal.state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Minimal footer for the selected pane: token usage when known, and a problem
/// indicator only when something is wrong. Detection details and freshness are
/// kept in the tooltip rather than on screen.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let ref = model.selection {
            let state = model.state(ref.targetID)
            let content = state.flatMap { content(ref, $0) }
            HStack(spacing: 10) {
                metadata(ref)
                Spacer(minLength: 8)
                if let pending = model.pendingNudges[ref] {
                    HStack(spacing: 8) {
                        NudgeRing(start: pending.start, fireAt: pending.fireAt, size: 12)
                        Button("Send Now") { model.sendNudgeNow(ref) }
                        Button("Cancel") { model.cancelNudge(ref) }
                    }
                    .buttonStyle(.hover)
                    .layoutPriority(1)
                    .transition(.opacity)
                }
                if let problem = content?.problem {
                    HStack(spacing: 10) {
                        Circle().fill(problem.color).frame(width: 7, height: 7)
                        Text(problem.text).lineLimit(1)
                    }
                    .layoutPriority(1)
                    .transition(.opacity)
                }
                if model.showsStatusField(.usage), let usage = content?.usage {
                    UsageView(usage: usage).layoutPriority(1)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .animation(Motion.quick, value: model.pendingNudges[ref] != nil)
            .animation(Motion.quick, value: content?.problem?.text)
            .padding(.horizontal, 12)
            .statusStripChrome()
            .help(content?.tooltip ?? "")
        }
    }

    /// The agent's identity (was its own bar above the terminal, now folded in
    /// here): account, server, container and working directory.
    @ViewBuilder private func metadata(_ ref: PaneRef) -> some View {
        HStack(spacing: 10) {
            if let agent = model.agentEntry(ref) {
                if model.showsStatusField(.model), let label = agent.modelLabel { chip(brandIcon(agent.kind), label) }
                if model.showsStatusField(.account) { chip(icon("person.crop.circle"), agent.configLabel) }
                if model.showsStatusField(.version), let version = agent.version { chip(icon("tag"), version) }
                if model.showsStatusField(.server) { chip(icon("server.rack"), agent.device.server) }
                if model.showsStatusField(.container) { chip(icon("shippingbox"), agent.device.name) }
                if model.showsStatusField(.folder) { chip(icon("folder"), agent.space.path) }
            } else if let pane = model.paneEntry(ref) {
                chip(icon("terminal"), pane.command)
                chip(icon("shippingbox"), pane.device.name)
                chip(icon("folder"), pane.space.path)
            }
        }
    }

    // A fixed icon box keeps the differently-shaped SF Symbols the same size.
    private func chip(_ icon: some View, _ text: String) -> some View {
        HStack(spacing: 4) {
            icon.frame(width: 15, height: 12)
            Text(text).truncationMode(.middle)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    @ViewBuilder private func brandIcon(_ kind: AgentKind) -> some View {
        if let resource = BrandIconLoader.agentIcon(for: kind) {
            BrandIcon(resource: resource, size: 12)
        } else {
            icon("terminal")
        }
    }

    private struct Problem { var color: Color; var text: String }
    private struct Content { var problem: Problem?; var usage: InventorySnapshot.AgentUsage?; var tooltip: String }

    /// Returns nil when there is nothing worth showing (healthy, no usage).
    private func content(_ ref: PaneRef, _ state: TargetState) -> Content? {
        let problem: Problem?
        if state.lastFailure != nil, state.snapshot == nil {
            problem = Problem(color: .red, text: "offline · \(state.lastFailure!.kind.rawValue)")
        } else if state.lastFailure != nil {
            problem = Problem(color: .orange, text: "stale")
        } else if let terminal = model.terminal(for: ref), terminal.isTrouble {
            problem = Problem(color: .orange, text: terminal.phaseText)
        } else {
            problem = nil
        }
        let usage = state.snapshot?.usage[ref.paneID]?.withInferredWindow()
        guard problem != nil || usage != nil else { return nil }
        return Content(problem: problem, usage: usage, tooltip: tooltip(ref, state))
    }

    /// The detail that used to crowd the bar, now hover-only.
    private func tooltip(_ ref: PaneRef, _ state: TargetState) -> String {
        var lines: [String] = []
        if let detection = state.detections[ref.paneID], detection.kind != .none {
            var parts = ["\(detection.kind.label) \(detection.version ?? "")".trimmingCharacters(in: .whitespaces)]
            if let directory = detection.configDirectory { parts.append(directory) }
            parts.append("\(detection.confidence.rawValue) confidence")
            lines.append(parts.joined(separator: " · "))
        }
        if let success = state.lastSuccess {
            lines.append("updated \(Int(max(0, Date().timeIntervalSince(success))))s ago")
        }
        if let terminal = model.terminal(for: ref), let geometry = terminal.geometry {
            lines.append("\(geometry.columns)×\(geometry.rows) · \(terminal.phaseText)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Mostly-graphical usage readout: a labelled bar + percent for context fill
/// and, when the status line reports them, the 5-hour and 7-day (weekly) limit
/// windows. When only an absolute context size is known (no window / percent),
/// it shows that number instead.
private struct UsageView: View {
    let usage: InventorySnapshot.AgentUsage

    var body: some View {
        HStack(spacing: 12) {
            if let fraction = usage.contextUsedFraction {
                Meter(label: "ctx", fraction: fraction, tooltip: contextTooltip)
            } else if let context = usage.contextTokens {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill").imageScale(.medium).foregroundStyle(.secondary)
                    Text(Self.short(context)).rollingNumber(context)
                }
                .font(.footnote).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .help("Context: \(context) tokens (the model's window is not in the log)")
            }
            if let h5 = usage.fiveHourPercent {
                Meter(label: "5h", fraction: h5 / 100, tooltip: "5-hour limit used: \(Int(h5.rounded()))%", resetsAt: usage.fiveHourResetsAt)
            }
            if let d7 = usage.sevenDayPercent {
                Meter(label: "7d", fraction: d7 / 100, tooltip: "Weekly (7-day) limit used: \(Int(d7.rounded()))%", resetsAt: usage.sevenDayResetsAt)
            }
            if usage.fiveHourPercent == nil, usage.sevenDayPercent == nil, let rate = usage.rateLimitPercent {
                Meter(label: "rate", fraction: rate / 100, tooltip: "Rate limit used: \(Int(rate.rounded()))%")
            }
        }
    }

    private var contextTooltip: String {
        if let t = usage.contextTokens, let w = usage.contextWindow {
            return "Context: \(Self.short(t)) / \(Self.short(w)) tokens"
        }
        if let p = usage.contextPercent { return "Context used: \(Int(p.rounded()))%" }
        return "Context"
    }

    static func short(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

/// A short text label, a bar, and a trailing percentage.
private struct Meter: View {
    let label: String
    let fraction: Double
    let tooltip: String
    var resetsAt: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Capsule().fill(.quaternary)
                .frame(width: 44, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(color)
                        .frame(width: 44 * max(0, min(1, fraction)), height: 6)
                }
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.footnote).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .rollingNumber(Int((fraction * 100).rounded()))
            if let reset = Self.resetText(resetsAt) {
                Text(reset).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .help(Self.resetText(resetsAt).map { "\(tooltip) · resets in \($0)" } ?? tooltip)
    }

    /// Compact time until the limit resets ("2d5h", "3h12m", "45m"); nil if
    /// unknown or already past.
    static func resetText(_ resetsAt: Int?) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt - Int(Date().timeIntervalSince1970)
        guard remaining > 0 else { return nil }
        let d = remaining / 86400, h = (remaining % 86400) / 3600, m = (remaining % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    private var color: Color {
        switch fraction {
        case ..<0.75: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

/// A tile card's measures.
private enum TileCard {
    static let radius: CGFloat = 8
    /// The surface keeps clear of the rounded corners: a Metal layer ignores
    /// SwiftUI clipping.
    static let surfaceInsets = EdgeInsets(top: 2, leading: 4, bottom: 4, trailing: 4)
    /// All of a card's height that is not its terminal.
    static var chromeHeight: CGFloat { TileHeader.height + surfaceInsets.top + surfaceInsets.bottom }
    /// How long surfaces wait for the cards to settle before fading in.
    static let settleDelay: Duration = .milliseconds(200)

    /// Where a card's terminal goes: under the header, inside the insets.
    static func content(of card: CGRect) -> CGRect {
        CGRect(x: card.minX + surfaceInsets.leading,
               y: card.minY + TileHeader.height + surfaceInsets.top,
               width: max(0, card.width - surfaceInsets.leading - surfaceInsets.trailing),
               height: max(0, card.height - chromeHeight))
    }
}

/// A tile's card: rounded, in the terminal's color, with a hairline border,
/// the header, and a focus ring on the tile that gets the keys. Off (one
/// agent shown alone) it is bare, so it can grow into a tile and back.
private struct TileCardView<Header: View>: View {
    @Environment(AppModel.self) private var model
    let on: Bool
    let focused: Bool
    /// A tile with no mirror yet, or on a view-only target.
    let placeholder: PaneRef?
    let header: Header

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: on ? TileCard.radius : 0)
        VStack(spacing: 0) {
            if on { header.transition(.opacity) }
            if let placeholder {
                PanePlaceholderView(ref: placeholder)
            } else {
                Color.clear
            }
        }
        .background(GhosttyRuntime.terminalBackground(for: model.terminalTheme).opacity(on ? 1 : 0), in: shape)
        .overlay {
            shape
                .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1)
                .opacity(on ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

/// A tile's title strip: the agent's icon, name, folder and container, how
/// long it has worked or been idle, and its status, with zoom and close on
/// hover. Click focuses the tile, double-click zooms it, and dragging the
/// strip onto another tile swaps the two.
private struct TileHeader: View {
    static let height: CGFloat = 28
    /// The coordinate space of the tiles, for finding where a drag is.
    static let space = "tiles"

    @Environment(AppModel.self) private var model
    let ref: PaneRef
    /// The drag's location in `space`.
    let onDrag: (CGPoint) -> Void
    let onDrop: () -> Void
    @State private var hovering = false

    var body: some View {
        let focused = model.selection == ref
        HStack(spacing: 6) {
            if let agent = model.agentEntry(ref) {
                if let resource = BrandIconLoader.agentIcon(for: agent.kind) {
                    BrandIcon(resource: resource, size: 13)
                }
                name(model.customName(agent.identityKey) ?? agent.title, focused: focused)
                place("\(agent.spaceLabel) · \(agent.device.name)")
                Spacer(minLength: 4)
                if let pending = model.pendingNudges[ref] {
                    NudgeRing(start: pending.start, fireAt: pending.fireAt)
                } else {
                    ActivityTime(entry: agent)
                }
                AgentStatusGlyph(activity: agent.activity, fault: agent.fault, retrying: agent.isRetrying, done: agent.isDone)
            } else if let pane = model.paneEntry(ref) {
                Image(systemName: "terminal").foregroundStyle(.tertiary)
                name(pane.title, focused: focused)
                place("\(pane.spaceLabel) · \(pane.device.name)")
                Spacer(minLength: 4)
            }
            if hovering {
                Button {
                    model.focusTile(ref)
                    model.toggleZoom()
                } label: {
                    Image(systemName: model.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(model.isZoomed ? "Show All" : "Zoom")
                Button { model.removeTile(ref) } label: { Image(systemName: "xmark") }
                    .help("Close")
            }
        }
        .animation(Motion.quick, value: hovering)
        .buttonStyle(.hover)
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(.bar, in: UnevenRoundedRectangle(topLeadingRadius: TileCard.radius, topTrailingRadius: TileCard.radius))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                .onChanged { onDrag($0.location) }
                .onEnded { _ in onDrop() }
        )
        .onTapGesture(count: 2) {
            model.focusTile(ref)
            model.toggleZoom()
        }
        .onTapGesture { model.focusTile(ref) }
        .debouncedHover { hovering = $0 }
    }

    private func name(_ text: String, focused: Bool) -> some View {
        Text(text)
            .fontWeight(.medium)
            .foregroundStyle(focused ? .primary : .secondary)
            .lineLimit(1)
            .layoutPriority(1)
    }

    private func place(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Shown in its own window; renders the same single mirror surface, which the
/// main detail pane releases while this window is open.
struct PoppedTerminalWindow: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef
    @State private var onScreen = false

    var body: some View {
        ZStack {
            GhosttyRuntime.terminalBackground(for: model.terminalTheme)
            if let terminal = model.terminal(for: ref) {
                MirroredSurfaceView(terminal: terminal)
            } else {
                Text("This agent is no longer available.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.agentEntry(ref)?.title ?? "Agent")
        .background(WindowVisibility(visible: $onScreen))
        .onChange(of: onScreen) { _, visible in model.setPopout(ref, visible: visible) }
        .onAppear { model.terminal(for: ref)?.setActive(true) }
        .onDisappear { model.returnFromWindow(ref) }
    }
}

/// A throwaway shell window (a direct pty, not in tmux). Closing it ends the
/// shell and its ssh connection, leaving nothing behind on the remote.
struct EphemeralTerminalWindow: View {
    @Environment(AppModel.self) private var model
    let spec: EphemeralTerminalSpec

    var body: some View {
        ZStack {
            GhosttyRuntime.terminalBackground(for: model.terminalTheme)
            if let terminal = model.ephemeralTerminal(for: spec) {
                EphemeralSurfaceView(terminal: terminal)
            } else {
                Text("Could not open a terminal here.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Terminal: \(spec.label)")
        .onAppear { model.ephemeralTerminal(for: spec)?.setActive(true) }
        .onDisappear { model.closeEphemeral(spec.id) }
    }
}

private struct EphemeralSurfaceView: View {
    let terminal: EphemeralTerminal

    var body: some View {
        TerminalSurfaceView(context: terminal.state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PoppedInfoView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Open in a separate window").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PanePlaceholderView: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef

    var body: some View {
        VStack(spacing: 10) {
            if let state = model.state(ref.targetID) {
                if state.target.access.allowsAttach {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "eye")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("View only")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.configError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Settings problem").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                SettingsLink { Text("Open Settings…") }
                    .padding(.top, 2)
            } else if model.hosts.isEmpty {
                Image(systemName: "server.rack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No hosts yet").font(.headline)
                SettingsLink { Text("Open Settings…") }
                    .padding(.top, 2)
            } else {
                Image(systemName: "terminal")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select an agent").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
