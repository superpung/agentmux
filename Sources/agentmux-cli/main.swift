import AgentMuxCore
import Foundation

// Development tool: runs the read-only inventory against configured targets.
//
//   agentmux-cli probe [--config path] [target-id ...]

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "probe" else {
    FileHandle.standardError.write(Data("usage: agentmux-cli probe [--config path] [target-id ...]\n".utf8))
    exit(2)
}

var configPath = "config/targets.local.json5"
var wanted: [String] = []
var iterator = arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    if argument == "--config", let path = iterator.next() {
        configPath = path
    } else {
        wanted.append(argument)
    }
}

let config: TargetsConfig
do {
    config = try TargetsConfig.load(from: URL(fileURLWithPath: configPath))
} catch {
    FileHandle.standardError.write(Data("cannot load \(configPath): \(error)\n".utf8))
    exit(1)
}

/// Remote text is untrusted: show control characters escaped.
func display(_ text: String) -> String {
    text.unicodeScalars.map { $0.properties.generalCategory == .control ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined()
}

for target in config.targets where wanted.isEmpty || wanted.contains(target.id) {
    guard let host = config.host(for: target) else { continue }
    let started = Date()
    let result = await TargetProbe.run(host: host, target: target)
    let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
    print("== \(target.id) (\(host.id), \(target.access.rawValue)) in \(elapsed)")

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
            continue
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
