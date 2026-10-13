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

    static let fontSize: CGFloat = 13

    let ref: PaneRef
    let state = TerminalViewState(controller: GhosttyRuntime.controller)
    /// Called (throttled) when the mirrored pane emits output, so the model can
    /// refresh this agent's state promptly while the user is watching it.
    @ObservationIgnored var onActivity: (@MainActor @Sendable () -> Void)?
    /// Last time an activity notification fired; confined to the mirror queue.
    @ObservationIgnored nonisolated(unsafe) private var lastActivityNotify = Date.distantPast
    private(set) var phase: Phase = .connecting
    /// The remote pane's size, which the app drives to match the local view.
    private(set) var geometry: PaneMirror.Geometry?
    private let mirror: PaneMirror
    private let session: InMemoryTerminalSession
    private let gate: InputGate

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
            // The local surface drives the remote window size, so the pane
            // reflows to fill the view (like a normal terminal) rather than
            // being letterboxed.
            resize: { viewport in
                mirror.setViewportSize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            }
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
        options.fontSize = Float(PaneTerminal.fontSize)
        state.configuration = options

        try mirror.start(
            onTerminalBytes: { [weak self] data in
                session.receive(data)
                self?.noteActivity()
            },
            onGeometry: { [weak self] geometry in
                Task { @MainActor in
                    self?.geometry = geometry
                    self?.fitFontToRemote(geometry)
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

    /// Keeps the mirror readable when another tmux client controls the shared
    /// window size. Normally the local surface drives the remote size, so the
    /// remote grid matches the surface grid. But `refresh-client -C` is only a
    /// soft request: when the user is attached at a larger size (window-size
    /// latest), the remote stays bigger than our surface and its wider rows wrap
    /// and garble. Scale the font so the remote grid fits the surface's pixel
    /// area; when the app owns the size the grids match and this is a no-op. It
    /// converges because each refit shrinks the font gap below the thrash guard.
    private func fitFontToRemote(_ geometry: PaneMirror.Geometry) {
        guard let m = state.surfaceSize,
              geometry.columns > 0, geometry.rows > 0,
              m.cellWidthPixels > 0, m.cellHeightPixels > 0,
              m.widthPixels > 0, m.heightPixels > 0 else { return }
        if Int(m.columns) == geometry.columns, Int(m.rows) == geometry.rows { return }
        let current = Double(state.fontSize ?? Float(Self.fontSize))
        guard current > 0 else { return }
        let fitWidth = current * Double(m.widthPixels) / (Double(geometry.columns) * Double(m.cellWidthPixels))
        let fitHeight = current * Double(m.heightPixels) / (Double(geometry.rows) * Double(m.cellHeightPixels))
        // A hair under the exact fit so the surface ends up at least as large as
        // the remote grid (a column short would still wrap).
        let target = max(5, min(fitWidth, fitHeight) * 0.99)
        guard abs(target - current) >= 0.5 else { return }
        _ = state.performBindingAction("set_font_size:\(String(format: "%.1f", target))")
    }

    /// Runs on the mirror's serial queue when pane output arrives. Throttled so
    /// a burst of output triggers at most one refresh every 1.5 s.
    nonisolated private func noteActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastActivityNotify) > 1.5 else { return }
        lastActivityNotify = now
        Task { @MainActor [weak self] in self?.onActivity?() }
    }

    var phaseText: String {
        switch phase {
        case .connecting: "Connecting…"
        case .live: "Mirroring · input goes to this pane only"
        case let .ended(reason): "Disconnected: \(reason) · input disabled"
        case let .stale(reason): "Stale: \(reason) · input disabled"
        }
    }

    /// The mirror is no longer usable (the server generation changed or the
    /// client ended), as opposed to merely connecting or live.
    var isTrouble: Bool {
        switch phase {
        case .connecting, .live: false
        case .ended, .stale: true
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

    /// Whether input can currently be delivered (mirror live and on screen).
    var canSend: Bool { gate.isOpen }

    /// Pastes `text`, then (when `submit`) presses Enter so an agent CLI runs
    /// the prompt. Returns false if input is not currently allowed.
    func send(_ text: String, submit: Bool) -> Bool {
        guard gate.isOpen, mirror.paste(text) else { return false }
        if submit { mirror.sendInput(Data([0x0d])) }
        return true
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
