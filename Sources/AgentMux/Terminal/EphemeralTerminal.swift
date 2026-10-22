import AgentMuxCore
import AppKit
import Foundation
import GhosttyTerminal
import Observation

/// Identifies one throwaway terminal window. A fresh `id` per invocation lets
/// several terminals open on the same target (WindowGroup dedupes by value).
struct EphemeralTerminalSpec: Codable, Hashable {
    var targetID: String
    var label: String
    var id: UUID
}

/// A throwaway shell in a target's container (or host), over a direct PTY that
/// runs `ssh -tt … docker exec -it … <shell>` — deliberately NOT through tmux.
/// Closing the view hangs up the pty, which ends ssh and the shell, so nothing
/// is created in or left behind in tmux.
@MainActor
@Observable
final class EphemeralTerminal {
    enum Phase: Equatable {
        case live
        /// The shell (or its ssh connection) ended; input is disabled.
        case ended(String)
    }

    let state = TerminalViewState(controller: GhosttyRuntime.controller)
    private(set) var phase: Phase = .live
    @ObservationIgnored private let session: InMemoryTerminalSession
    @ObservationIgnored private var pty: PTYProcess?

    init(host: HostConfig, target: TargetConfig) throws {
        let destination = try SSHDestination(host.sshDestination)
        let remote = RemoteCommand.shell(in: try target.executionContext())
        let argv = RemoteCommand.ssh(destination, options: SSHOptions(), allocateTTY: true, remote: remote)
        let pty = try PTYProcess(
            executable: RemoteCommand.sshExecutable,
            arguments: argv,
            environment: ["TERM": "xterm-256color"],
            columns: 80, rows: 24
        )
        let session = InMemoryTerminalSession(
            // Keys and the local view's size drive the pty directly — no tmux.
            write: { data in pty.write(data) },
            resize: { viewport in pty.resize(columns: viewport.columns, rows: viewport.rows) }
        )
        self.pty = pty
        self.session = session

        state.makePlatformView = {
            let view = PasteInterceptingTerminalView(frame: .zero)
            // No tmux here, so paste and Shift+Enter go straight to the pty.
            view.onPaste = { text in pty.write(Data(text.utf8)); return true }
            view.onShiftEnter = { pty.write(Data([0x0a])) }
            return view
        }
        var options = TerminalSurfaceOptions(backend: .inMemory(session))
        options.fontSize = Float(GhosttyRuntime.currentFontSize)
        state.configuration = options

        pty.start(
            onOutput: { data in session.receive(data) },
            onExit: { [weak self] _ in
                Task { @MainActor in self?.markEnded("session ended") }
            }
        )
    }

    var phaseText: String {
        switch phase {
        case .live: "Terminal · not in tmux, ends when closed"
        case let .ended(reason): "Ended: \(reason) · input disabled"
        }
    }

    func setActive(_ active: Bool) {
        state.isSurfaceVisible = active
        if active { state.requestFocus() }
    }

    func close() {
        pty?.hangUp()
        pty = nil
    }

    private func markEnded(_ reason: String) {
        if case .ended = phase { return }
        phase = .ended(reason)
    }
}
