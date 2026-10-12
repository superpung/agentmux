import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("showResourceInspector") private var showInspector = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView()
                .toolbar {
                    ToolbarItem {
                        Button { showInspector.toggle() } label: {
                            Label("Resources", systemImage: "chart.bar.xaxis")
                        }
                        .help("Show container and host resources")
                    }
                }
        }
        .inspector(isPresented: $showInspector) {
            ResourceInspector()
                .inspectorColumnWidth(min: 230, ideal: 280, max: 380)
        }
        .onChange(of: model.selection) { _, selection in
            for terminal in model.terminals.values {
                terminal.setActive(terminal.ref == selection)
            }
        }
    }

    /// Selecting a row opens its mirror (on an attachable target) and marks it
    /// active; `model.select` does both.
    private var selectionBinding: Binding<PaneRef?> {
        Binding(
            get: { model.selection },
            set: { ref in
                if let ref { model.select(ref) } else { model.selection = nil }
            }
        )
    }
}
