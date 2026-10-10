import AgentMuxCore
import Foundation

// Development tool for the remote path.
//
//   agentmux-cli probe [target-id ...]           read-only inventory
//   agentmux-cli clients <target-id>             read-only client list with AgentMux tags
//   agentmux-cli attach-test <target-id> <tmux-target> [--seconds N] [--type TEXT] [--leak] [--then-select PANE]
//                                                attach like the app does (test targets only)
//   agentmux-cli release-orphans <target-id>     release every AgentMux-tagged client (test targets only)
//   agentmux-cli mirror-test <target-id> <session-id> <pane-id> [--type TEXT] [--paste TEXT]
//                                                mirror a pane over control mode, optionally typing
//
// Global option: --config path (default config/targets.local.json5)

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var configPath = "config/targets.local.json5"
if let index = arguments.firstIndex(of: "--config"), index + 1 < arguments.count {
    configPath = arguments[index + 1]
    arguments.removeSubrange(index ... index + 1)
}
guard let command = arguments.first else {
    fail("usage: agentmux-cli probe|clients|attach-test|release-orphans ...", code: 2)
}
let rest = Array(arguments.dropFirst())

let config: TargetsConfig
do {
    config = try TargetsConfig.load(from: URL(fileURLWithPath: configPath))
} catch {
    fail("cannot load \(configPath): \(error)")
}

func target(_ id: String?) -> (HostConfig, TargetConfig) {
    guard let id, let target = config.targets.first(where: { $0.id == id }), let host = config.host(for: target) else {
        fail("unknown target \(id ?? "<none>")")
    }
    return (host, target)
}

/// Remote text is untrusted: show control characters escaped.
func display(_ text: String) -> String {
    text.unicodeScalars.map { $0.properties.generalCategory == .control ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined()
}

func option(_ name: String, in list: [String]) -> String? {
    guard let index = list.firstIndex(of: name), index + 1 < list.count else { return nil }
    return list[index + 1]
}

switch command {
case "probe":
    for target in config.targets where rest.isEmpty || rest.contains(target.id) {
        guard let host = config.host(for: target) else { continue }
        let started = Date()
        let result = await TargetProbe.run(host: host, target: target)
        print("== \(target.id) (\(host.id), \(target.access.rawValue)) in \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
        printProbe(result)
    }

case "clients":
    let (host, target) = target(rest.first)
    let tmux = try target.executionContext().tmux
    let tm = ShellQuote.command(tmux.argv)
    let script = """
    \(tm) list-clients -F '#{client_pid} #{client_tty} #{client_session} #{client_flags} #{client_width}x#{client_height}' 2>&1 | while read -r pid rest; do
      tag=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^AGENTMUX_CLIENT=//p' | head -n 1)
      echo "client $pid $rest tag=${tag:--}"
    done
    \(tm) list-panes -a -F 'pane #{pane_id} #{session_name}:#{window_index}.#{pane_index} pane_active=#{pane_active} window_active=#{window_active}' 2>&1

    """
    switch await RemoteScript.run(script, host: host, target: target) {
    case let .success(text): print(display(text).replacingOccurrences(of: "\\u{a}", with: "\n"), terminator: "")
    case let .failure(failure): fail("FAILED \(failure.kind.rawValue): \(failure.detail)")
    }

case "attach-test":
    let (host, target) = target(rest.first)
    guard rest.count >= 2 else { fail("attach-test <target-id> <tmux-target> [--seconds N] [--type TEXT] [--leak]", code: 2) }
    let seconds = option("--seconds", in: rest).flatMap(Double.init) ?? 5
    let text = option("--type", in: rest)
    let terminal: RemoteTerminal
    do {
        terminal = try RemoteTerminal(host: host, target: target, tmuxTarget: rest[1], columns: 100, rows: 30)
    } catch {
        fail("cannot attach: \(error)")
    }
    let received = ByteCounter()
    terminal.start(onOutput: { received.add($0.count) }, onExit: { print("ssh ended: \($0)") })
    print("attached with tag \(terminal.clientTag)")
    if let pane = option("--then-select", in: rest) {
        // Experiment: change the window's shared active pane from outside.
        try await Task.sleep(for: .seconds(1.5))
        let tmux = ShellQuote.command(try target.executionContext().tmux.argv)
        print("external select-pane -t \(pane): \(await RemoteScript.run("\(tmux) select-pane -t \(ShellQuote.word(pane)) && echo ok", host: host, target: target))")
    }
    if let text {
        try await Task.sleep(for: .seconds(2))
        terminal.write(Data((text + "\r").utf8))
        print("typed \(text.debugDescription) + CR")
    }
    try await Task.sleep(for: .seconds(seconds))
    print("received \(received.value) bytes")
    if rest.contains("--leak") {
        terminal.hangUpLocally()
        print("hung up locally only (client left for release-orphans)")
    } else {
        print("release: \(await terminal.close())")
    }
    try await Task.sleep(for: .seconds(1))

case "mirror-test":
    // mirror-test <target-id> <session-id> <pane-id> [--type TEXT] [--paste TEXT] [--seconds N]
    let (host, target) = target(rest.first)
    guard rest.count >= 3 else { fail("mirror-test <target-id> <session-id> <pane-id> [--type TEXT] [--paste TEXT] [--seconds N]", code: 2) }
    let mirror: PaneMirror
    do {
        mirror = try PaneMirror(host: host, target: target, session: rest[1], paneID: rest[2])
    } catch {
        fail("cannot mirror: \(error)")
    }
    let received = ByteCounter()
    let first = ByteCounter()
    try mirror.start(
        onTerminalBytes: { data in
            if first.value == 0 { first.add(data.count) } else { received.add(data.count) }
        },
        onGeometry: { print("geometry \($0.columns)x\($0.rows)") },
        onEnded: { print("ended: \($0)") }
    )
    print("mirror client tag \(mirror.clientTag)")
    try await Task.sleep(for: .seconds(2))
    print("initial screen \(first.value) bytes")
    if let text = option("--type", in: rest) {
        mirror.sendInput(Data((text + "\r").utf8))
        print("typed \(text.debugDescription) + CR")
    }
    if let text = option("--paste", in: rest) {
        print("paste accepted: \(mirror.paste(text))")
    }
    try await Task.sleep(for: .seconds(option("--seconds", in: rest).flatMap(Double.init) ?? 3))
    print("live output \(received.value) bytes")
    mirror.close()
    try await Task.sleep(for: .seconds(2))

case "release-orphans":
    let (host, target) = target(rest.first)
    guard target.access == .test else { fail("release-orphans is limited to test targets") }
    print(await ClientRelease.release(host: host, context: try target.executionContext(), options: SSHOptions(), tags: []))

default:
    fail("unknown command \(command)", code: 2)
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.withLock { count += n } }
    var value: Int { lock.withLock { count } }
}

func printProbe(_ result: Result<InventorySnapshot, RemoteFailure>) {
    switch result {
    case let .failure(failure):
        print("   FAILED \(failure.kind.rawValue): \(failure.detail)")
    case let .success(snapshot):
        if let container = snapshot.container {
            print("   container \(container.id.prefix(12)) \(container.status) started \(container.startedAt)")
        }
        print("   uid \(snapshot.uid.map(String.init) ?? "?")  \(snapshot.tmuxVersion ?? "tmux ?")")
        if let failure = snapshot.failure {
            print("   tmux: \(failure.kind.rawValue) \(failure.detail)")
            return
        }
        if let server = snapshot.server {
            print("   server pid \(server.pid) start \(server.startTime) socket \(display(server.socketPath))")
        }
        let detections = AgentDetector.detect(snapshot)
        for session in snapshot.sessions {
            print("   session \(session.id) \(display(session.name))")
            let rows = snapshot.memberships.filter { $0.sessionID == session.id }
            for windowID in rows.map(\.windowID).uniqued() {
                let window = snapshot.windows.first { $0.id == windowID }
                print("     window \(windowID) \(display(window?.name ?? ""))")
                for row in rows where row.windowID == windowID {
                    guard let pane = snapshot.pane(row.paneID) else { continue }
                    var line = "       pane \(pane.id) \(display(pane.currentCommand)) \(display(pane.currentPath))"
                    if let detection = detections[pane.id], detection.kind != .none {
                        line += "  -> \(detection.kind.rawValue)"
                        if let version = detection.version { line += " \(version)" }
                        if let directory = detection.configDirectory { line += " [\(directory)]" }
                        line += " (\(detection.confidence.rawValue): \(detection.evidence.joined(separator: ", ")))"
                        if !detection.children.isEmpty {
                            line += " children: \(detection.children.map { "\($0.kind.rawValue)#\($0.pid)" }.joined(separator: " "))"
                        }
                    }
                    print(line)
                }
            }
        }
        print("   \(snapshot.panes.count) panes, \(snapshot.processes.count) processes under panes, \(snapshot.agents.count) agent candidates")
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
