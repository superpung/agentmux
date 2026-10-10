import AgentMuxCore
import AppKit
import Foundation
import GhosttyTerminal
import Observation

/// Connects one Ghostty surface to one `RemoteTerminal`.
@MainActor
@Observable
final class TerminalController {
    enum Phase: Equatable {
        case connecting
        case connected
        /// The connection ended; input is disabled. The pane is untouched.
        case ended(String)
        /// The pane this view was opened for no longer exists in this form.
        case stale(String)
    }

    let ref: PaneRef
    let state = TerminalViewState()
    private(set) var phase: Phase = .connecting
    private let remote: RemoteTerminal
    private let session: InMemoryTerminalSession

    var clientTag: String { remote.clientTag }

    init(ref: PaneRef, host: HostConfig, target: TargetConfig) throws {
        let remote = try RemoteTerminal(host: host, target: target, tmuxTarget: ref.paneID, columns: 100, rows: 30)
        let gate = InputGate()
        let session = InMemoryTerminalSession(
            write: { data in
                // Input only reaches the remote while the view is live and selected.
                if gate.isOpen { remote.write(data) }
            },
            resize: { viewport in remote.resize(columns: viewport.columns, rows: viewport.rows) }
        )
        self.ref = ref
        self.remote = remote
        self.session = session
        self.gate = gate

        remote.start(
            onOutput: { [weak self] data in
                session.receive(data)
                if gate.claimFirstOutput() {
                    Task { @MainActor in self?.markConnected() }
                }
            },
            onExit: { [weak self] termination in
                gate.close()
                Task { @MainActor in self?.markEnded(termination) }
            }
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        scheduleSmokeIfRequested()
    }

    private let gate: InputGate

    /// Only the terminal on screen may send input; hidden ones drop it even
    /// if they still hold keyboard focus.
    func setActive(_ active: Bool) {
        gate.setSelected(active)
        state.isSurfaceVisible = active
        if active { state.requestFocus() }
    }

    func markStale(reason: String) {
        gate.close()
        phase = .stale(reason)
    }

    func close() async {
        gate.close()
        await remote.close()
    }

    /// Stops input and hands over the connection, for closing it off the
    /// main actor while the app quits.
    func detachForQuit() -> RemoteTerminal {
        gate.close()
        return remote
    }

    private func markConnected() {
        if phase == .connecting { phase = .connected }
    }

    private func markEnded(_ termination: PTYProcess.Termination) {
        if case .stale = phase { return }
        phase = switch termination {
        case let .exited(code): .ended("connection closed (exit \(code))")
        case let .signaled(signal): .ended("connection closed (signal \(signal))")
        }
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
                _ = self.state.paste(text: input)
                _ = self.state.sendKey(.enter)
            }
            try? await Task.sleep(for: .seconds(3))
            let text = self?.session.readViewportText() ?? "<no surface attached>"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            // Not from inside this main-actor job: quitting waits for work
            // that needs the main thread.
            AppDelegate.performOnMainRunLoop { NSApp.terminate(nil) }
        }
    }
}

/// Thread-safe switch read on the terminal's write path.
final class InputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var selected = true
    private var sawOutput = false

    var isOpen: Bool { lock.withLock { open && selected } }

    func setSelected(_ value: Bool) {
        lock.withLock { selected = value }
    }

    func close() {
        lock.withLock { open = false }
    }

    /// True exactly once, for the first output chunk.
    func claimFirstOutput() -> Bool {
        lock.withLock {
            defer { sawOutput = true }
            return !sawOutput
        }
    }
}
