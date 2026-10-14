import Foundation

/// The selected agent process's own resource use, read inside its container.
/// Distinct from the container aggregate: this is just the agent's `ps` line
/// plus the free space on the filesystem holding its working directory.
public struct AgentResources: Sendable, Equatable {
    /// Lifetime-average CPU, as `ps` reports it (can exceed 100 on many cores).
    public var cpuPercent: Double
    public var rssKB: Int
    public var uptimeSeconds: Int
    /// Workspace filesystem usage; 0 total means it was not read.
    public var diskUsedKB: Int
    public var diskTotalKB: Int

    public init(cpuPercent: Double = 0, rssKB: Int = 0, uptimeSeconds: Int = 0, diskUsedKB: Int = 0, diskTotalKB: Int = 0) {
        self.cpuPercent = cpuPercent
        self.rssKB = rssKB
        self.uptimeSeconds = uptimeSeconds
        self.diskUsedKB = diskUsedKB
        self.diskTotalKB = diskTotalKB
    }

    public var diskPercent: Double { diskTotalKB > 0 ? Double(diskUsedKB) / Double(diskTotalKB) * 100 : 0 }
    public var hasDisk: Bool { diskTotalKB > 0 }
}

/// Reads one agent process's resource use, running `ps` and `df` inside the
/// agent's own execution context (its container). Fully read-only; it never
/// touches the agent's files. Scoped to a single pid so only the selected
/// agent is probed, not every container every poll.
public enum AgentResourceProbe {
    public static func run(
        host: HostConfig,
        target: TargetConfig,
        pid: Int,
        cwd: String?,
        options: SSHOptions = SSHOptions(),
        timeoutSeconds: Int = 15
    ) async -> Result<AgentResources, RemoteFailure> {
        let dfLine: String
        if let cwd, !cwd.isEmpty {
            dfLine = "df -Pk '\(singleQuoteEscaped(cwd))' 2>/dev/null | awk 'NR==2{print $3\" \"$2}'"
        } else {
            dfLine = ""
        }
        let script = """
        echo '@@proc'
        ps -o %cpu=,rss=,etimes= -p \(pid) 2>/dev/null
        echo '@@disk'
        \(dfLine)
        echo '@@end'
        """
        let result = await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: timeoutSeconds)
        switch result {
        case let .failure(failure):
            return .failure(failure)
        case let .success(text):
            return .success(parse(text))
        }
    }

    static func parse(_ text: String) -> AgentResources {
        var out = AgentResources()
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@") { section = line; continue }
            if line.isEmpty { continue }
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch section {
            case "@@proc":
                if f.count >= 3 {
                    out.cpuPercent = Double(f[0]) ?? 0
                    out.rssKB = Int(f[1]) ?? 0
                    out.uptimeSeconds = Int(f[2]) ?? 0
                }
            case "@@disk":
                if f.count >= 2, let used = Int(f[0]), let total = Int(f[1]) {
                    out.diskUsedKB = used
                    out.diskTotalKB = total
                }
            default:
                break
            }
        }
        return out
    }

    private static func singleQuoteEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
