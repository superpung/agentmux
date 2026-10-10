import AgentMuxCore
import AppKit
import Foundation
import GhosttyTerminal
import Observation

/// One Ghostty surface mirroring one remote pane through `PaneMirror`.
@MainActor
@Observable
final class PaneTerminal {
    enum Phase: Equatable {
        case connecting
        case live
        /// The mirror ended; input is disabled. The pane is untouched.
        case ended(String)
        /// The tmux server changed under this view.
        case stale(String)
    }

    static let baseFontSize: CGFloat = 13

    let ref: PaneRef
    let state = TerminalViewState(controller: GhosttyRuntime.controller)
    private(set) var phase: Phase = .connecting
    /// The remote pane's size. The font is scaled so the whole grid fits.
    private(set) var geometry: PaneMirror.Geometry?
    /// Font size chosen so `geometry` fits the available area, in points.
    private(set) var fittedFontSize: CGFloat = PaneTerminal.baseFontSize
    private let mirror: PaneMirror
    private let session: InMemoryTerminalSession
    private let gate: InputGate

    /// Cell size at the base font, in points, measured once from the surface.
    @ObservationIgnored private var baseCellPoints: CGSize?
    @ObservationIgnored private var availableSize: CGSize = .zero
    @ObservationIgnored private var resyncTask: Task<Void, Never>?

    var clientTag: String { mirror.clientTag }

    init(ref: PaneRef, sessionID: String, host: HostConfig, target: TargetConfig) throws {
        let mirror = try PaneMirror(host: host, target: target, session: sessionID, paneID: ref.paneID)
        let gate = InputGate()
        let session = InMemoryTerminalSession(
            write: { data in
                // Keys and mouse reports reach the pane only while this view
                // is selected and live.
                if gate.isOpen { mirror.sendInput(data) }
            },
            // The remote pane keeps its own size; the local grid follows it.
            resize: { _ in }
        )
        self.ref = ref
        self.mirror = mirror
        self.session = session
        self.gate = gate

        state.makePlatformView = { [weak self] in
            let view = PasteInterceptingTerminalView(frame: .zero)
            view.onPaste = { text in self?.paste(text) ?? false }
            return view
        }
        var options = TerminalSurfaceOptions(backend: .inMemory(session))
        // Pin the starting font so the measured base cell size is deterministic.
        options.fontSize = Float(PaneTerminal.baseFontSize)
        state.configuration = options

        try mirror.start(
            onTerminalBytes: { data in session.receive(data) },
            onGeometry: { [weak self] geometry in
                Task { @MainActor in
                    self?.geometry = geometry
                    self?.recomputeFont()
                }
            },
            onEnded: { [weak self] reason in
                gate.close()
                Task { @MainActor in self?.markEnded(reason) }
            }
        )
        gate.markLive()
        phase = .live
        scheduleSmokeIfRequested()
    }

    var phaseText: String {
        switch phase {
        case .connecting: "Connecting…"
        case .live: "Mirroring · input goes to this pane only"
        case let .ended(reason): "Disconnected: \(reason) · input disabled"
        case let .stale(reason): "Stale: \(reason) · input disabled"
        }
    }

    /// Called by the view with its available size and the surface's current
    /// cell metrics. Learns the base cell size (before any font override),
    /// then scales the font so the whole remote grid fits.
    func updateLayout(available: CGSize, cellPixels: CGSize?, scale: CGFloat) {
        availableSize = available
        if baseCellPoints == nil, fittedFontSize == PaneTerminal.baseFontSize,
           let cellPixels, cellPixels.width > 0, cellPixels.height > 0, scale > 0
        {
            baseCellPoints = CGSize(width: cellPixels.width / scale, height: cellPixels.height / scale)
        }
        recomputeFont()
    }

    /// Scales the font down so `geometry` columns × rows fit `availableSize`.
    /// Only shrinks: a small pane keeps the base font and sits top-left.
    private func recomputeFont() {
        guard let geometry, let cell = baseCellPoints,
              availableSize.width > 1, availableSize.height > 1,
              geometry.columns > 0, geometry.rows > 0 else { return }
        let base = PaneTerminal.baseFontSize
        let fitWidth = availableSize.width / (CGFloat(geometry.columns) * cell.width)
        let fitHeight = availableSize.height / (CGFloat(geometry.rows) * cell.height)
        let scale = min(1, fitWidth, fitHeight)
        // Half-point steps so small size changes do not thrash the surface.
        let font = max(4, (base * scale * 2).rounded(.down) / 2)
        guard abs(font - fittedFontSize) >= 0.25 else { return }
        fittedFontSize = font
        state.configuration.fontSize = Float(font)
        // Changing the font rebuilds the surface; redraw once it settles.
        resyncTask?.cancel()
        resyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            self?.mirror.resync()
        }
    }

    /// Only the terminal on screen may send input; hidden ones drop it even
    /// if they still hold keyboard focus.
    func setActive(_ active: Bool) {
        gate.setSelected(active)
        state.isSurfaceVisible = active
        if active { state.requestFocus() }
    }

    /// Pastes through tmux so bracketed paste follows the pane's real mode.
    func paste(_ text: String) -> Bool {
        guard gate.isOpen else { return false }
        return mirror.paste(text)
    }

    func resync() {
        mirror.resync()
    }

    func markStale(reason: String) {
        gate.close()
        phase = .stale(reason)
    }

    func close() {
        gate.close()
        resyncTask?.cancel()
        mirror.close()
    }

    private func markEnded(_ reason: String) {
        if case .stale = phase { return }
        phase = .ended(reason)
    }

    /// AGENTMUX_SMOKE_DUMP=<path> with AGENTMUX_OPEN: type AGENTMUX_SMOKE_INPUT
    /// after the view connects, write the viewport text to <path> and quit.
    private func scheduleSmokeIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["AGENTMUX_SMOKE_DUMP"] else { return }
        let input = environment["AGENTMUX_SMOKE_INPUT"]
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if let input, let self {
                _ = self.paste(input)
                try? await Task.sleep(for: .milliseconds(300))
                self.mirror.sendInput(Data("\r".utf8))
            }
            try? await Task.sleep(for: .seconds(3))
            let text = self?.session.readViewportText() ?? "<no surface attached>"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            AppDelegate.performOnMainRunLoop { NSApp.terminate(nil) }
        }
    }
}

/// ⌘V goes to tmux (`paste-buffer -p`) instead of Ghostty's local paste:
/// the local mirror cannot know whether the remote program enabled
/// bracketed paste before the view was opened.
final class PasteInterceptingTerminalView: AppTerminalView {
    var onPaste: ((String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v",
           window?.firstResponder === self
        {
            if let text = NSPasteboard.general.string(forType: .string) {
                _ = onPaste?(text)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Thread-safe switch read on the terminal's write path.
final class InputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var live = false
    private var closed = false
    private var selected = true

    var isOpen: Bool { lock.withLock { live && !closed && selected } }

    func markLive() {
        lock.withLock { live = true }
    }

    func setSelected(_ value: Bool) {
        lock.withLock { selected = value }
    }

    func close() {
        lock.withLock { closed = true }
    }
}
