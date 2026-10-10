// Adapted from a Mac agent console's DevicePopover
// (a Mac agent console, an upstream reference, a noncommercial license;
// reused for personal, non-distributed use).
import AgentMuxCore
import SwiftUI

/// Target scope switcher that opens upward from the sidebar footer.
struct DevicePopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("DEVICES")
                .font(.system(size: 10.5, weight: .medium))
                .kerning(0.3)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 9)
                .frame(height: 24, alignment: .leading)

            Button {
                model.showDevicePanel = false
                model.deviceFilter = nil
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13))
                        .foregroundStyle(model.deviceFilter == nil ? Theme.text : Theme.textSecondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All Devices")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Text("\(model.targets.count) devices · \(model.targets.filter(\.isOnline).count) connected")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if model.deviceFilter == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.text)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowButtonStyle(selected: model.deviceFilter == nil))

            ForEach(model.targets) { state in
                DevicePopoverRow(state: state, isActive: state.id == model.deviceFilter) {
                    model.showDevicePanel = false
                    model.deviceFilter = state.id
                }
            }
        }
        .padding(5)
        .frame(width: 272)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

private struct DevicePopoverRow: View {
    let state: TargetState
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let device = state.device
        Button(action: action) {
            HStack(spacing: 9) {
                DeviceIcon(osID: device.osID, size: 13)
                    .foregroundStyle(isActive ? Theme.text : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: device.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                        if state.target.access == .observe {
                            Text("view only")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textGhost)
                        }
                    }
                    Text(verbatim: subtitle(device))
                        .font(.system(size: 11))
                        .foregroundStyle(state.lastFailure == nil ? Theme.textTertiary : Theme.danger)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered || isActive ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
    }

    private var dotColor: Color {
        if state.lastFailure != nil { return Theme.danger }
        return state.isOnline ? Theme.success : Theme.warning
    }

    private func subtitle(_ device: DeviceInfo) -> String {
        if let failure = state.lastFailure { return failure.kind.rawValue }
        return device.subtitle
    }
}
