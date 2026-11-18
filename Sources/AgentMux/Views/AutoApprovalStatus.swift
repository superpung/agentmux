import AgentMuxCore
import SwiftUI

struct AutoApprovalStatus: View {
    @Environment(AppModel.self) private var model
    let ref: PaneRef

    var body: some View {
        if model.agentEntry(ref) != nil {
            let entry = model.autoMode.entries[ref]
            HStack(spacing: 7) {
                if let start = entry?.countdown.startedAt {
                    ScheduledActionControls(start: start, fireAt: start.addingTimeInterval(ApprovalCountdown.delay),
                                            countdownAction: "Yes",
                                            cancelHelp: "Skip this request; Auto mode stays on for new requests",
                                            cancel: { model.autoMode.cancel(ref) })
                } else if let entry {
                    let unsupported = model.agentEntry(ref)?.activity.needsAttention == true
                        && model.state(ref.targetID)?.snapshot?.approvals[ref.paneID] == nil
                    if entry.approving {
                        Text("Approving…")
                    } else if entry.needsManualApproval || unsupported {
                        Text("Manual approval")
                            .help(entry.message ?? "Choose this request manually")
                    }
                }
                // Keep the switch at the same right edge when countdown
                // controls arrive, so Cancel cannot move under its pointer.
                Toggle(isOn: Binding(get: { model.autoMode.entries[ref] != nil },
                                     set: { model.autoMode.setEnabled($0, for: ref, model: model) })) {
                    Label(entry == nil ? "Auto" : "Auto on", systemImage: entry == nil ? "bolt" : "bolt.fill")
                        .foregroundStyle(entry == nil ? Color.secondary : Color.primary)
                }
                .toggleStyle(AutoModeToggleStyle())
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Auto mode for this agent")
                .disabled(entry == nil && !model.autoMode.canEnable(ref, model: model))
                .help("Automatically choose one-time Yes for this agent’s command and edit approvals after 5 seconds. Off on app restart or agent replacement.")
            }
            .help(entry?.message ?? "Recognized Yes/No approvals are confirmed after 5 seconds for this agent")
        }
    }
}

/// A quiet status-bar selection; the shared hover style supplies press and
/// keyboard behavior without the native button toggle's solid accent fill.
struct AutoModeToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
        }
        .buttonStyle(HoverButtonStyle(keepsColor: true))
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(configuration.isOn ? 0.07 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary.opacity(configuration.isOn ? 0.10 : 0), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
