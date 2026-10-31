import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var windowID = UUID()
    @State private var onScreen = false

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
                        Button { model.showInbox.toggle() } label: {
                            Label("Notifications", systemImage: model.inbox.unreadCount > 0 ? "bell.badge" : "bell")
                                .symbolRenderingMode(model.inbox.unreadCount > 0 ? .multicolor : .monochrome)
                        }
                        .help(model.inbox.unreadCount > 0 ? "Notifications (\(model.inbox.unreadCount) unread)" : "Notifications")
                        .popover(isPresented: $model.showInbox, arrowEdge: .bottom) {
                            InboxView().environment(model)
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
        // Agents shown here count as seen only while the window is on screen.
        .background(WindowVisibility(visible: $onScreen))
        .onChange(of: onScreen, initial: true) { _, visible in model.setMainWindow(windowID, visible: visible) }
        .onDisappear { model.setMainWindow(windowID, visible: false) }
        // The palette fades in over a lightly dimmed window and settles
        // down from a slightly smaller size; it fades out on close.
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
