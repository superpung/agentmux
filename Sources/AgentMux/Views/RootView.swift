import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView()
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
