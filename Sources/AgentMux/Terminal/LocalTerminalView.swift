import AgentMuxCore
import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI

/// M0 smoke test: a local login shell in a Ghostty surface, wired through
/// our own PTYProcess so the same plumbing later carries `ssh`.
@MainActor
final class LocalTerminal: ObservableObject {
    let state = TerminalViewState()
    private var process: PTYProcess?
    private var session: InMemoryTerminalSession?

    func start() {
        guard process == nil else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"

        let process: PTYProcess
        do {
            process = try PTYProcess(
                executable: shell,
                arguments: ["-l"],
                environment: environment,
                columns: 80,
                rows: 24
            )
        } catch {
            NSLog("AgentMux: spawn failed: \(error)")
            return
        }

        let session = InMemoryTerminalSession(
            write: { data in process.write(data) },
            resize: { viewport in process.resize(columns: viewport.columns, rows: viewport.rows) }
        )
        process.start(
            onOutput: { data in session.receive(data) },
            onExit: { termination in
                let code: UInt32 = switch termination {
                case let .exited(code): UInt32(bitPattern: code)
                case let .signaled(signal): 128 + UInt32(bitPattern: signal)
                }
                session.finish(exitCode: code, runtimeMilliseconds: 0)
            }
        )
        self.process = process
        self.session = session
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        scheduleSmokeDumpIfRequested(session)
    }

    func stop() {
        process?.hangUp()
        process = nil
    }

    /// AGENTMUX_SMOKE_DUMP=<path>: after the shell has had time to draw,
    /// write the visible viewport text there and quit, so a script can check
    /// the pty -> parser -> surface path without a screenshot.
    private func scheduleSmokeDumpIfRequested(_ session: InMemoryTerminalSession) {
        guard let path = ProcessInfo.processInfo.environment["AGENTMUX_SMOKE_DUMP"] else { return }
        if let input = ProcessInfo.processInfo.environment["AGENTMUX_SMOKE_INPUT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                _ = self?.state.paste(text: input)
                _ = self?.state.sendKey(.enter)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let text = session.readViewportText() ?? "<no surface attached>"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

struct LocalTerminalView: View {
    @StateObject private var terminal = LocalTerminal()

    var body: some View {
        TerminalSurfaceView(context: terminal.state)
            .onAppear { terminal.start() }
            .onDisappear { terminal.stop() }
    }
}
