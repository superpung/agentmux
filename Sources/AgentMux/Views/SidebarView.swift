// Layout and row design adapted from a Mac agent console's SidebarView
// (a Mac agent console, an upstream reference, a noncommercial license;
// reused for personal, non-distributed use).
import AgentMuxCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var collapsed: Bool
    var width: CGFloat
    @State private var spacesExpanded = true
    @State private var agentsExpanded = true
    @State private var terminalsExpanded = false
    @State private var deviceButtonHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Titlebar strip: traffic lights on the left, collapse toggle on the right.
            HStack {
                Spacer()
                TitlebarIconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘B)") {
                    collapsed = true
                }
            }
            .padding(.horizontal, 10)
            .frame(height: TitlebarMetrics.height)
            .windowTitlebarInteraction()

            Spacer().frame(height: 8)

            VStack(spacing: 1) {
                actionRow(icon: "magnifyingglass", label: "Search", shortcut: "⌘K") {
                    model.showSearch = true
                }
                actionRow(icon: "arrow.clockwise", label: "Refresh", shortcut: "⌘R") {
                    model.refreshAll()
                }
            }
            .padding(.horizontal, 10)

            Spacer().frame(height: 10)

            ScrollView {
                VStack(spacing: 1) {
                    groupHeader("Spaces", expanded: $spacesExpanded)
                    if spacesExpanded {
                        allSpacesRow
                        ForEach(model.spaceEntries) { entry in
                            SpaceRowView(entry: entry)
                        }
                    }
                    Spacer().frame(height: 10)

                    groupHeader("Agents", expanded: $agentsExpanded)
                    if agentsExpanded {
                        let agents = model.agentEntries
                        if agents.isEmpty {
                            Text(verbatim: emptyAgentsHint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textGhost)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        ForEach(agents) { entry in
                            AgentRowView(entry: entry)
                        }
                    }
                    Spacer().frame(height: 10)

                    let panes = model.paneEntries
                    if !panes.isEmpty {
                        groupHeader("Terminals", expanded: $terminalsExpanded, count: panes.count)
                        if terminalsExpanded {
                            ForEach(panes) { entry in
                                PaneRowView(entry: entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .clipped()

            Spacer(minLength: 0)
            footer
        }
        .frame(width: width)
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
    }

    private var emptyAgentsHint: String {
        if let failure = model.targets.compactMap(\.lastFailure).first, model.targets.allSatisfy({ $0.snapshot == nil }) {
            return failure.kind.rawValue
        }
        return model.targets.contains { $0.snapshot == nil } ? "Connecting…" : "No agents"
    }

    private func actionRow(icon: String, label: LocalizedStringKey, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
            }
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .focusEffectDisabled()
    }

    private func groupHeader(_ title: LocalizedStringKey, expanded: Binding<Bool>, count: Int? = nil) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textGhost)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textGhost)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var allSpacesRow: some View {
        let selected = model.spaceFilter == nil
        return Button {
            model.spaceFilter = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                Text("All Spaces")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer()
                Text("\(model.scopeAgentCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
        .focusEffectDisabled()
    }

    // MARK: Footer (device scope)

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                model.showDevicePanel.toggle()
            } label: {
                HStack(spacing: 6) {
                    if let device = model.devices.first(where: { $0.id == model.deviceFilter }) {
                        DeviceIcon(osID: device.osID, size: 10)
                            .foregroundStyle(Theme.textSecondary)
                        Text(verbatim: device.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                        Text("All Devices")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                    }
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 6, height: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(deviceButtonHovered || model.showDevicePanel
                        ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(Theme.itemWash))
            )
            .onHover { deviceButtonHovered = $0 }

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: SidebarFooterMetrics.deviceSwitcherHeight)
    }

    /// Green when every target in scope is online, red when any failed.
    private var connectionDotColor: Color {
        let scoped = model.targets.filter { model.deviceFilter == nil || $0.id == model.deviceFilter }
        if scoped.contains(where: { $0.lastFailure != nil }) { return Theme.danger }
        if scoped.allSatisfy(\.isOnline) { return Theme.success }
        return Theme.warning
    }
}

// MARK: - Rows

private struct SpaceRowView: View {
    @Environment(AppModel.self) private var model
    let entry: SpaceEntry
    @State private var hovered = false

    var body: some View {
        let selected = model.spaceFilter == entry.key
        Button {
            model.spaceFilter = selected ? nil : entry.key
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                Text(verbatim: entry.label)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if let attention = entry.attention {
                    AgentStatusGlyph(activity: attention)
                }
                if model.showsRowDeviceBadges {
                    DeviceChip(device: entry.device)
                }
                Text("\(entry.agentCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(Text(verbatim: entry.key.path))
    }
}

private struct AgentRowView: View {
    @Environment(AppModel.self) private var model
    let entry: AgentEntry
    @State private var hovered = false

    var body: some View {
        let selected = model.selection == entry.ref
        Button {
            model.select(entry.ref)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    AgentStatusGlyph(activity: entry.activity)
                }
                HStack(spacing: 5) {
                    AgentKindBadge(kind: entry.kind)
                    Text("·")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textGhost)
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(verbatim: entry.spaceLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if entry.activity.needsAttention {
                        Text("needs input")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.warning)
                    }
                    if model.showsRowDeviceBadges {
                        DeviceChip(device: entry.device)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(minHeight: 51)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(Text(verbatim: "\(entry.location) · \(entry.space.path)"))
    }
}

private struct PaneRowView: View {
    @Environment(AppModel.self) private var model
    let entry: PaneEntry
    @State private var hovered = false

    var body: some View {
        let selected = model.selection == entry.ref
        Button {
            model.select(entry.ref)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Text(verbatim: entry.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: entry.location)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textGhost)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(verbatim: entry.spaceLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.showsRowDeviceBadges {
                        DeviceChip(device: entry.device)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(height: 51)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(Text(verbatim: entry.space.path))
    }
}
