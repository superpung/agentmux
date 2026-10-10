// Window chrome adapted from a Mac agent console
// (a Mac agent console, an upstream reference, a noncommercial license;
// reused for personal, non-distributed use).
import AppKit
import SwiftUI

/// 28pt matches the system traffic-light centerline.
enum TitlebarMetrics {
    static let height: CGFloat = 28
    static let trafficLightClearance: CGFloat = 78
}

enum SidebarFooterMetrics {
    static let deviceSwitcherHeight: CGFloat = 40
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.material = material
    }
}

/// Lets a custom titlebar strip drag the window and zoom on double-click,
/// like the real titlebar it replaces.
private struct WindowTitlebarInteraction: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        WindowTitlebarInteractionView()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class WindowTitlebarInteractionView: NSView {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased() {
            case "minimize": window.performMiniaturize(nil)
            case "none": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

extension View {
    func windowTitlebarInteraction() -> some View {
        background(WindowTitlebarInteraction())
    }
}

/// Small icon button for the titlebar strip.
struct TitlebarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? AnyShapeStyle(Theme.itemWash) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(help)
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || configuration.isPressed ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
    }
}

// MARK: - Resizable sidebar

enum SidebarWidth {
    static let defaultWidth: Double = 280
    static let range: ClosedRange<Double> = 220 ... 480
    static let storageKey = "sidebar.width"

    static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Sidebar, a 1pt resize line and the detail pane side by side.
struct SidebarSplit<Sidebar: View, Detail: View>: View {
    let collapsed: Bool
    @AppStorage(SidebarWidth.storageKey) private var storedWidth = SidebarWidth.defaultWidth
    @ViewBuilder let sidebar: (CGFloat) -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        let width = SidebarWidth.clamp(storedWidth)
        HStack(spacing: 0) {
            sidebar(width)
                .frame(width: collapsed ? 0 : width, alignment: .trailing)
                .clipped()
            Rectangle()
                .fill(Theme.sidebarBorder)
                .frame(width: collapsed ? 0 : 1)
                .overlay {
                    if !collapsed {
                        SidebarResizeHandle(width: $storedWidth).frame(width: 7)
                    }
                }
                .ignoresSafeArea()
                .zIndex(1)
            detail()
        }
        .animation(.easeInOut(duration: 0.2), value: collapsed)
    }
}

/// AppKit handle: takes the first click in an inactive window and owns its
/// cursor rect. Double-click restores the default width.
private struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: Double

    func makeNSView(context _: Context) -> SidebarResizeHandleView {
        SidebarResizeHandleView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ view: SidebarResizeHandleView, context _: Context) {
        view.currentWidth = { width }
        view.setWidth = { width = $0 }
    }
}

final class SidebarResizeHandleView: NSView {
    var currentWidth: () -> Double = { SidebarWidth.defaultWidth }
    var setWidth: (Double) -> Void = { _ in }
    private var dragStart: (x: CGFloat, width: Double)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            setWidth(SidebarWidth.defaultWidth)
            return
        }
        dragStart = (event.locationInWindow.x, SidebarWidth.clamp(currentWidth()))
    }

    override func mouseDragged(with event: NSEvent) { follow(event) }

    override func mouseUp(with event: NSEvent) {
        follow(event)
        dragStart = nil
    }

    private func follow(_ event: NSEvent) {
        guard let start = dragStart else { return }
        setWidth(SidebarWidth.clamp(start.width + event.locationInWindow.x - start.x))
    }
}
