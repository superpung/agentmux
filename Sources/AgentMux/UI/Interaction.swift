import SwiftUI

/// The app's motion, in one place so the same kind of change moves the same
/// way everywhere.
enum Motion {
    /// Small things appearing, disappearing or changing: hover feedback,
    /// buttons shown on hover, status marks, spinners, highlights.
    static let quick = Animation.easeOut(duration: 0.15)
    /// Something arriving over or reshaping the content: the palette, tiles
    /// joining, leaving or zooming.
    static let panel = Animation.spring(duration: 0.22, bounce: 0.12)
    /// Rows of a list moving, arriving or leaving.
    static let list = Animation.snappy(duration: 0.28)

    /// How long the pointer rests before controls shown on hover appear,
    /// and how long after it leaves they go: passing over a row on the way
    /// elsewhere doesn't flash them.
    static let hoverIn: Duration = .milliseconds(90)
    static let hoverOut: Duration = .milliseconds(220)
}

extension View {
    /// Reports hovering after the pointer has rested (`Motion.hoverIn`) and
    /// its end a moment after it leaves (`Motion.hoverOut`), for controls
    /// shown on hover. Feedback on the control under the pointer itself
    /// stays immediate.
    func debouncedHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(DebouncedHover(action: action))
    }

    /// The rounded wash behind a clickable thing while the pointer is over
    /// it, as on the sidebar footer's buttons.
    func hoverBackground(cornerRadius: CGFloat = 5) -> some View {
        modifier(HoverBackground(cornerRadius: cornerRadius))
    }
}

private struct DebouncedHover: ViewModifier {
    let action: (Bool) -> Void
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onHover { inside in
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(for: inside ? Motion.hoverIn : Motion.hoverOut)
                guard !Task.isCancelled else { return }
                action(inside)
            }
        }
        .onDisappear { pending?.cancel() }
    }
}

private struct HoverBackground: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
    }
}

/// An icon or short text button without a border: secondary until the
/// pointer is over it, then primary on a rounded wash, darker while pressed.
/// The look of the sidebar footer's buttons, for every such button.
struct HoverButtonStyle: ButtonStyle {
    /// Keep the label's own color (an accent arrow, say) instead of the
    /// secondary-to-primary change.
    var keepsColor = false

    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration, keepsColor: keepsColor)
    }

    private struct HoverButton: View {
        let configuration: Configuration
        let keepsColor: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let wash = configuration.isPressed ? 0.14 : hovering && enabled ? 0.08 : 0
            configuration.label
                .padding(.horizontal, 5)
                .frame(minWidth: 24, minHeight: 22)
                .modifier(Emphasis(applies: !keepsColor, on: hovering && enabled))
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(wash)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
        }
    }
}

/// Secondary, or primary under the pointer; nothing when the label keeps
/// its own color.
private struct Emphasis: ViewModifier {
    let applies: Bool
    let on: Bool

    func body(content: Content) -> some View {
        if applies {
            content.foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        } else {
            content
        }
    }
}

/// A whole row that is one button (a dashboard or menu-bar agent): a
/// rounded wash under the row while the pointer is over it, as menus
/// highlight their items.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButton(configuration: configuration)
    }

    private struct RowButton: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}
