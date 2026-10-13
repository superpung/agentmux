import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.toggleInspector() } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .help("Show resources and files")
                    }
                }
        }
        .inspector(isPresented: $model.inspectorVisible) {
            InspectorPanel()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 460)
        }
        .overlay {
            if model.showCommandPalette {
                CommandPalette(isPresented: paletteBinding)
                    .transition(.opacity)
            }
        }
        .onChange(of: model.selection) { _, selection in
            for terminal in model.terminals.values {
                terminal.setActive(terminal.ref == selection)
            }
        }
    }

    private var paletteBinding: Binding<Bool> {
        Binding(get: { model.showCommandPalette }, set: { model.showCommandPalette = $0 })
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
