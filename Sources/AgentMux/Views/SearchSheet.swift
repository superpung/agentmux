import AgentMuxCore
import SwiftUI

/// ⌘K: find an agent or pane by title, directory, device or tmux location;
/// Return opens the first match.
struct SearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Hit: Identifiable {
        var ref: PaneRef
        var title: String
        var detail: String
        var kind: AgentKind
        var id: PaneRef { ref }
    }

    private var hits: [Hit] {
        let agents = model.allAgentEntries.map {
            Hit(ref: $0.ref, title: $0.title, detail: "\($0.kind.label) · \($0.space.path) · \($0.device.name) · \($0.location)", kind: $0.kind)
        }
        let panes = model.paneEntries.map {
            Hit(ref: $0.ref, title: $0.title, detail: "\($0.command) · \($0.space.path) · \($0.device.name) · \($0.location)", kind: .none)
        }
        let all = agents + panes
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return all }
        return all.filter { hit in
            let haystack = (hit.title + " " + hit.detail).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search agents, directories, devices…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { open(hits.first) }
            }
            .padding(14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(hits) { hit in
                        Button { open(hit) } label: {
                            HStack(spacing: 10) {
                                if hit.kind == .none {
                                    Image(systemName: "terminal")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 16)
                                } else if let icon = BrandIconLoader.agentIcon(for: hit.kind) {
                                    BrandIcon(resource: icon, size: 14).frame(width: 16)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: hit.title)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    Text(verbatim: hit.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SidebarRowButtonStyle(selected: hit.ref == hits.first?.ref))
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 560, height: 420)
        .onAppear { focused = true }
    }

    private func open(_ hit: Hit?) {
        guard let hit else { return }
        model.deviceFilter = nil
        model.spaceFilter = nil
        model.select(hit.ref)
        dismiss()
    }
}
