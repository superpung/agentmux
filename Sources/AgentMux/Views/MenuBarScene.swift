import AppKit
import AgentMuxCore
import SwiftUI

/// The always-on menu-bar item. Its glyph reflects the most urgent state, with
/// a count; the popover lists the agents that need you and those working, and
/// clicking one brings AgentMux forward on that agent.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let attention = model.allAgentEntries.filter { $0.activity.needsAttention }.count
        let working = model.allAgentEntries.filter { $0.activity == .working }.count
        HStack(spacing: 3) {
            if attention > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                Text("\(attention)")
            } else if working > 0 {
                Image(systemName: "bolt.fill")
                Text("\(working)")
            } else {
                Image(systemName: "terminal")
            }
        }
    }
}

struct MenuBarContent: View {
    let model: AppModel

    private var agents: [AgentEntry] { model.allAgentEntries }
    private var attention: [AgentEntry] { agents.filter { $0.activity.needsAttention } }
    private var working: [AgentEntry] { agents.filter { $0.activity == .working } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AgentMux").font(.headline)
                Spacer()
                Text(countsText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if agents.isEmpty {
                        Text(model.hosts.isEmpty ? "No hosts configured." : "No agents found.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(14)
                    }
                    section("Needs attention", attention)
                    section("Working", working)
                }
            }
            .frame(maxHeight: 360)

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var countsText: String {
        "\(working.count) working · \(attention.count) need you"
    }

    @ViewBuilder private func section(_ title: String, _ list: [AgentEntry]) -> some View {
        if !list.isEmpty {
            Text(title.uppercased())
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
            ForEach(list) { agent in
                Button { jump(to: agent.ref) } label: {
                    HStack(spacing: 8) {
                        brandIcon(agent.kind).frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.customName(agent.identityKey) ?? agent.title).lineLimit(1)
                            Text(agent.device.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        AgentStatusGlyph(activity: agent.activity)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open AgentMux") { activate() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private func brandIcon(_ kind: AgentKind) -> some View {
        if let resource = BrandIconLoader.agentIcon(for: kind) {
            BrandIcon(resource: resource, size: 14)
        } else {
            Image(systemName: "terminal")
        }
    }

    private func jump(to ref: PaneRef) {
        activate()
        model.select(ref)
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain && window.title != "Sessions" {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
