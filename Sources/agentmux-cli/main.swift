import AgentMuxCore
import Foundation

// Development tool for the remote path. A "target" is "<hostId>/<container>",
// or a bare "<hostId>" with --container NAME (any container, need not be
// monitored). Hosts come from the app's settings.json.
//
//   agentmux-cli probe [target ...]              read-only inventory (no args = all monitored)
//   agentmux-cli clients <target>                read-only client list with AgentMux tags
//   agentmux-cli attach-test <target> <tmux-target> [--seconds N] [--type TEXT] [--leak] [--then-select PANE]
//                                                attach like the app does (uses a test-access target)
//   agentmux-cli release-orphans <target>        release every AgentMux-tagged client
//   agentmux-cli containers <target> [--all]     list containers on the target's host (read-only)
//   agentmux-cli mirror-test <target> <session-id> <pane-id> [--type TEXT] [--paste TEXT]
//                                                mirror a pane over control mode, optionally typing
//
// Global options: --settings path, --container NAME

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var settingsPath: String?
if let index = arguments.firstIndex(of: "--settings"), index + 1 < arguments.count {
    settingsPath = arguments[index + 1]
    arguments.removeSubrange(index ... index + 1)
}
guard let command = arguments.first else {
    fail("usage: agentmux-cli probe|clients|attach-test|release-orphans|containers|mirror-test ...", code: 2)
}
let rest = Array(arguments.dropFirst())

let settings: AppSettings = settingsPath
    .map { AppSettings.loadOrImport(url: URL(fileURLWithPath: $0)) }
    ?? AppSettings.loadOrImport()

/// All monitored targets, as the app would run them.
func allTargets() -> [(HostConfig, TargetConfig)] {
    settings.monitoredContainers.compactMap { key in
        guard let parts = AppSettings.splitKey(key),
              let host = settings.hosts.first(where: { $0.id == parts.hostID }) else { return nil }
        return (host, TargetConfig.discovered(host: host, container: parts.container))
    }
}

/// Resolves "<hostId>/<container>" or "<hostId>" (+ --container NAME) to a
/// target. `access` lets dev commands request test rights.
func target(_ spec: String?, access: TargetConfig.Access = .interact) -> (HostConfig, TargetConfig) {
    guard let spec else { fail("missing target (<hostId>/<container>)") }
    let hostID: String
    var container: String?
    if let slash = spec.firstIndex(of: "/") {
        hostID = String(spec[..<slash])
        container = String(spec[spec.index(after: slash)...])
    } else {
        hostID = spec
        container = option("--container", in: rest)
    }
    guard let host = settings.hosts.first(where: { $0.id == hostID }) else { fail("unknown host \(hostID)") }
    guard let container, !container.isEmpty else { fail("specify a container: \(hostID)/<container> or --container NAME") }
    var target = TargetConfig.discovered(host: host, container: container)
    target.access = access
    return (host, target)
}

/// Resolves a host from "<hostId>" or "<hostId>/<anything>".
func host(_ spec: String?) -> HostConfig {
    guard let spec else { fail("missing host id") }
    let hostID = spec.firstIndex(of: "/").map { String(spec[..<$0]) } ?? spec
    guard let host = settings.hosts.first(where: { $0.id == hostID }) else { fail("unknown host \(hostID)") }
    return host
}

/// Dev-only target on an isolated `agentmux-test` named socket, never the real
/// default tmux. attach-test / release-orphans operate only here, so they
/// cannot touch the user's actual sessions in a monitored container.
func testTarget(_ spec: String?) -> (HostConfig, TargetConfig) {
    var (host, target) = target(spec, access: .test)
    target.tmuxSocket = .init(mode: .name, value: "agentmux-test")
    return (host, target)
}

/// Positional arguments: drops flags and the value after `--container`.
func positional(_ args: [String]) -> [String] {
    var result: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--container" { i += 2; continue }
        if a.hasPrefix("-") { i += 1; continue }
        result.append(a); i += 1
    }
    return result
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
    let selected = positional(rest)
    let targets = selected.isEmpty ? allTargets() : selected.map { target($0) }
    for (host, target) in targets {
        let started = Date()
        let result = await TargetProbe.run(host: host, target: target)
        print("== \(target.id) (\(host.id)) in \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
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
    let (host, target) = testTarget(rest.first)
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

case "containers":
    let host = host(rest.first)
    switch await DockerDiscovery.list(host: host, includeStopped: rest.contains("--all")) {
    case let .success(list):
        print("== \(list.count) containers on \(host.sshDestination) ==")
        for c in list { print("  \(c.running ? "●" : "○") \(c.name)  [\(c.fullID.prefix(12))]  \(c.image)  \(c.status)") }
    case let .failure(failure): fail("FAILED \(failure.kind.rawValue): \(failure.detail)")
    }

case "release-orphans":
    let (host, target) = testTarget(rest.first)
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
                        if let m = snapshot.models[pane.id] { line += " model=\(m)"; if let e = snapshot.efforts[pane.id] { line += "/\(e)" } }
                        let ev = detection.pid.flatMap { snapshot.agents[$0] }
                        let activity = ActivityDetector.resolve(kind: detection.kind, logEvent: ev?.logEvent, logAgeSeconds: ev?.logAgeSeconds, screenState: snapshot.screenStates[pane.id], logState: snapshot.logStates[pane.id], title: pane.title)
                        line += " {\(activity.activity.rawValue)/\(activity.confidence.rawValue)}"
                        let logEventStr = String(describing: ev?.logEvent)
                        let logAgeStr = String(describing: ev?.logAgeSeconds)
                        let screenStr = String(describing: snapshot.screenStates[pane.id])
                        let logStateStr = String(describing: snapshot.logStates[pane.id])
                        let titleStr = String(describing: pane.title)
                        line += " <in logEvent=\(logEventStr) logAge=\(logAgeStr) screen=\(screenStr) logState=\(logStateStr) title=\(titleStr)>"
                        if let u = snapshot.usage[pane.id] {
                            var parts: [String] = []
                            if let c = u.contextTokens { parts.append("ctx \(c)\(u.contextWindow.map { "/\($0)" } ?? "")") }
                            if let cp = u.contextPercent { parts.append("ctx% \(cp)") }
                            if let r = u.rateLimitPercent { parts.append("limit \(r)%") }
                            if let h = u.fiveHourPercent { parts.append("5h \(h)%") }
                            if let d = u.sevenDayPercent { parts.append("7d \(d)%") }
                            if !parts.isEmpty { line += " usage[\(parts.joined(separator: " "))]" }
                        }
                        if let a = snapshot.lastActiveSeconds[pane.id] { line += " active[\(a)s]" }
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
