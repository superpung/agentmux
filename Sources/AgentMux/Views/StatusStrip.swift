import SwiftUI

/// Shared chrome for the two bottom status strips — the sidebar's fleet footer
/// and the detail view's per-agent status bar. They sit flush at the window's
/// bottom edge, so a single fixed height keeps them visually aligned regardless
/// of each one's content (the footer's icon buttons are taller than the status
/// bar's text, which is what made them differ before).
enum StatusStrip {
    /// Tall enough for the footer's 24×22 icon buttons with a little breathing
    /// room; a standard macOS bottom-bar height.
    static let height: CGFloat = 28
}

/// Shared by error auto-continue and approval confirmation. Each caller owns
/// its scheduling and validation; the countdown and controls have one layout.
struct ScheduledActionControls: View {
    let start: Date
    let fireAt: Date
    var countdownAction: String? = nil
    var sendNow: (() -> Void)? = nil
    var cancelHelp = "Cancel this scheduled action"
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            NudgeRing(start: start, fireAt: fireAt, size: 12,
                      helpText: countdownAction == nil ? "Continues automatically" : "Approves after the countdown")
            if let countdownAction {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text("\(countdownAction) in \(max(0, Int(ceil(fireAt.timeIntervalSince(context.date)))))s")
                        .monospacedDigit()
                }
            }
            if let sendNow { Button("Send Now", action: sendNow) }
            Button("Cancel", action: cancel).help(cancelHelp)
        }
        .buttonStyle(.hover)
    }
}

extension View {
    /// Pins a bottom status strip to the shared height and `.bar` material, with
    /// its content vertically centred. Callers pass only horizontal padding.
    func statusStripChrome() -> some View {
        frame(height: StatusStrip.height)
            .background(.bar)
    }
}
