// Window layout adapted from a Mac agent console's RootView
// (a Mac agent console, an upstream reference, a noncommercial license;
// reused for personal, non-distributed use).
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebarCollapsed = false

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottomLeading) {
            SidebarSplit(collapsed: sidebarCollapsed) { width in
                SidebarView(collapsed: $sidebarCollapsed, width: width)
            } detail: {
                DetailView(sidebarCollapsed: $sidebarCollapsed)
            }

            // In-window device panel, opening upward from the footer.
            if model.showDevicePanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { model.showDevicePanel = false }
                DevicePopover()
                    .padding(.leading, 10)
                    .padding(.bottom, 46)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                    .background(
                        Button("") { model.showDevicePanel = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    )
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.showDevicePanel)
        .background(
            Button("") { sidebarCollapsed.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { model.showSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
        .sheet(isPresented: $model.showSearch) { SearchSheet() }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 620)
        .onChange(of: model.selection) { _, selection in
            for terminal in model.terminals.values {
                terminal.setActive(terminal.ref == selection)
            }
        }
    }
}
