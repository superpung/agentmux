import SwiftUI

/// Which view the combined container window shows.
enum ContainerTab: String, CaseIterable, Sendable {
    case sessions, accounts
    var label: String { self == .sessions ? "Sessions" : "Accounts" }
}

/// One window for per-container management, sharing a single container picker:
/// the tmux tree (Sessions — the only place tmux objects are created or killed)
/// and the Claude account link map (Accounts).
struct ContainerWindow: View {
    @Environment(AppModel.self) private var model
    @State private var targetID = ""

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
                Picker("Container", selection: $targetID) {
                    ForEach(model.targets) { Text($0.device.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                Picker("View", selection: $model.containerTab) {
                    ForEach(ContainerTab.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            switch model.containerTab {
            case .sessions: SessionsWindow(targetID: $targetID)
            case .accounts: AccountLinksWindow(targetID: $targetID)
            }
        }
        .navigationTitle(model.containerTab.label)
        .onAppear {
            if targetID.isEmpty {
                targetID = model.selection?.targetID ?? model.targets.first?.id ?? ""
            }
        }
    }
}
