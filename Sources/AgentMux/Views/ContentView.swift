import AgentMuxCore
import GhosttyTerminal
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 480)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh all targets now")
            }
        }
        .onChange(of: model.selection) { _, selection in
            for terminal in model.terminals.values {
                terminal.setActive(terminal.ref == selection)
            }
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let ref = model.selection, let state = model.state(ref.targetID) {
                PaneHeaderView(ref: ref, state: state)
                Divider()
            }
            ZStack {
                // Every open terminal stays mounted so its screen survives
                // switching; only the selected one is visible and live.
                ForEach(Array(model.terminals.values), id: \.ref) { terminal in
                    let selected = terminal.ref == model.selection
                    TerminalSurfaceView(context: terminal.state)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                }
                if let ref = model.selection {
                    if model.terminal(for: ref) == nil {
                        PanePlaceholderView(ref: ref)
                    }
                } else {
                    EmptyStateView()
                }
            }
            if let ref = model.selection, let terminal = model.terminal(for: ref) {
                Divider()
                TerminalFooterView(terminal: terminal)
            }
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.configError {
                Text("No target configuration").font(.headline)
                Text(verbatim: model.configPath ?? "").font(.caption).textSelection(.enabled)
                Text(verbatim: error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Select an agent or a pane").foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
