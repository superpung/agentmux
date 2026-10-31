import AgentMuxCore
import SwiftUI

/// The notification list behind the toolbar bell: newest first, grouped by
/// day, unread marked with a dot. All / Unread filter, mark read or unread,
/// delete (hover, swipe or right-click), and clear. Clicking a row opens its
/// agent and marks it read.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("inboxUnreadOnly") private var unreadOnly = false

    private struct DaySection: Identifiable {
        var id: String { title }
        var title: String
        var items: [InboxItem]
    }

    private var sections: [DaySection] {
        let calendar = Calendar.current
        var result: [DaySection] = []
        for item in model.inbox.items where !unreadOnly || !item.isRead {
            let title = calendar.isDateInToday(item.date) ? "Today"
                : calendar.isDateInYesterday(item.date) ? "Yesterday"
                : "Earlier"
            if result.last?.title == title {
                result[result.count - 1].items.append(item)
            } else {
                result.append(DaySection(title: title, items: [item]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            let sections = sections
            if sections.isEmpty {
                Image(systemName: "bell.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                InboxRow(item: item) {
                                    model.openInboxItem(item.id)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .animation(Motion.list, value: sections.flatMap { $0.items.map { "\($0.id)\($0.isRead)" } })
            }
        }
        .frame(width: 400, height: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Notifications").font(.headline)
            Spacer()
            Picker("Show", selection: $unreadOnly) {
                Text("All").tag(false)
                Text("Unread").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { model.markAllInboxRead() } label: {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(.hover)
            .help("Mark All as Read")
            .disabled(model.inbox.unreadCount == 0)
            Menu {
                Button("Mark All as Read") { model.markAllInboxRead() }
                    .disabled(model.inbox.unreadCount == 0)
                Divider()
                Button("Clear Read") {
                    model.removeInboxItems(model.inbox.items.filter(\.isRead).map(\.id))
                }
                .disabled(!model.inbox.items.contains(where: \.isRead))
                Button("Clear All", role: .destructive) {
                    model.removeInboxItems(model.inbox.items.map(\.id))
                }
                .disabled(model.inbox.items.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(minWidth: 24, minHeight: 22)
            .hoverBackground()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct InboxRow: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            Image(systemName: item.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(item.kind.tint)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.agent)
                        .fontWeight(item.isRead ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering {
                        actions
                    } else {
                        Text(RelativeTime.short(Int(Date().timeIntervalSince(item.date))) ?? "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .animation(Motion.quick, value: hovering)
                (Text(item.kind.label) + Text([item.detail, item.place].compactMap { $0 }.map { " · \($0)" }.joined()))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .debouncedHover { hovering = $0 }
        .help(item.date.formatted(date: .abbreviated, time: .shortened))
        .contextMenu {
            Button("Open Agent", action: open)
            Button(item.isRead ? "Mark as Unread" : "Mark as Read") { model.markInboxRead(item.id, !item.isRead) }
            Divider()
            Button("Delete", role: .destructive) { model.removeInboxItems([item.id]) }
        }
        .swipeActions(edge: .leading) {
            Button { model.markInboxRead(item.id, !item.isRead) } label: {
                Label(item.isRead ? "Unread" : "Read", systemImage: item.isRead ? "envelope.badge" : "envelope.open")
            }
            .tint(.accentColor)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.removeInboxItems([item.id]) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.markInboxRead(item.id, !item.isRead) } label: {
                Image(systemName: item.isRead ? "envelope.badge" : "envelope.open")
            }
            .help(item.isRead ? "Mark as Unread" : "Mark as Read")
            Button { model.removeInboxItems([item.id]) } label: {
                Image(systemName: "xmark")
            }
            .help("Delete")
        }
        .buttonStyle(.hover)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension InboxItem.Kind {
    var label: String {
        switch self {
        case .finished: "Finished"
        case .needsInput: "Needs you"
        case .usageLimit: "Usage limit"
        case .error: "Stopped on an error"
        case .autoContinued: "Auto-continued"
        case .gaveUp: "Auto-continue stopped"
        }
    }

    var symbol: String {
        switch self {
        case .finished: "checkmark.circle.fill"
        case .needsInput: "exclamationmark.circle.fill"
        case .usageLimit: "hourglass.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .autoContinued: "arrow.clockwise.circle.fill"
        case .gaveUp: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .finished: Theme.success
        case .needsInput: Theme.warning
        case .usageLimit: Color(nsColor: .systemPurple)
        case .error, .gaveUp: Theme.danger
        case .autoContinued: Color(nsColor: .systemBlue)
        }
    }
}
