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

extension View {
    /// Pins a bottom status strip to the shared height and `.bar` material, with
    /// its content vertically centred. Callers pass only horizontal padding.
    func statusStripChrome() -> some View {
        frame(height: StatusStrip.height)
            .background(.bar)
    }
}
