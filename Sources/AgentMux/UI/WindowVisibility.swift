import AppKit
import SwiftUI

/// Reports whether its window is on screen: not minimized, hidden, or fully
/// covered.
struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = { visible = $0 }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.report = { visible = $0 }
    }

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return send(false) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(self?.window?.occlusionState.contains(.visible) ?? false) }
            }
            send(window.occlusionState.contains(.visible))
        }

        /// After the current view update, which may not change state.
        private func send(_ visible: Bool) {
            DispatchQueue.main.async { [weak self] in self?.report?(visible) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
