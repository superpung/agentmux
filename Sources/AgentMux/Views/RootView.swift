import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView()
                .toolbar {
                    // Files and New Terminal act on the selected agent, so they
                    // are hidden on the dashboard (nothing selected).
                    if model.selection != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button { if let spec = model.selectedFilesSpec { openWindow(value: spec) } } label: {
                                Label("Files", systemImage: "folder")
                            }
                            .help("Browse this agent's files")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { if let spec = model.newTerminalSpec() { openWindow(value: spec) } } label: {
                                Label("New Terminal", systemImage: "terminal")
                            }
                            .help("Open a throwaway shell in this agent's container")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.toggleInspector() } label: {
                            Label("Resources", systemImage: "sidebar.right")
                        }
                        .help("Show container and host resources")
                    }
                }
        }
        .inspector(isPresented: $model.inspectorVisible) {
            ResourceInspector()
                .inspectorColumnWidth(min: 260, ideal: 330, max: 460)
        }
        .onChange(of: model.previewRequest) { _, request in
            if let request { openWindow(value: request.spec) }
        }
        .overlay {
            if model.showCommandPalette {
                CommandPalette(isPresented: paletteBinding)
                    .transition(.opacity)
            }
        }
    }

    private var paletteBinding: Binding<Bool> {
        Binding(get: { model.showCommandPalette }, set: { model.showCommandPalette = $0 })
    }
}
