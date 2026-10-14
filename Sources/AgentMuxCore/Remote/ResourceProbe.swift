import Foundation

/// GPU utilisation, when `nvidia-smi` is present and a driver is loaded.
public struct GPUResources: Sendable, Equatable, Identifiable {
    public var index: Int
    public var name: String
    public var utilizationPercent: Double
    public var memUsedMB: Int
    public var memTotalMB: Int
    public var id: Int { index }

    public init(index: Int, name: String, utilizationPercent: Double, memUsedMB: Int, memTotalMB: Int) {
        self.index = index
        self.name = name
        self.utilizationPercent = utilizationPercent
        self.memUsedMB = memUsedMB
        self.memTotalMB = memTotalMB
    }
}

/// One mounted filesystem's usage, from `df` (read-only).
public struct DiskUsage: Sendable, Equatable, Identifiable {
    public var mount: String
    public var usedKB: Int
    public var totalKB: Int
    public var id: String { mount }

    public init(mount: String, usedKB: Int, totalKB: Int) {
        self.mount = mount
        self.usedKB = usedKB
        self.totalKB = totalKB
    }

    public var percent: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) * 100 : 0 }
}

/// One container's live resource use, from `docker stats` (read-only). The
/// memory / network / block figures are kept as Docker's own formatted strings;
/// the two percentages are parsed for the meters. The I/O rates are not from
/// Docker — the app fills them by differencing two snapshots (nil until then).
public struct ContainerResources: Sendable, Equatable {
    public var name: String
    public var cpuPercent: Double
    public var memPercent: Double
    public var memText: String
    public var netText: String
    public var blockText: String
    public var pids: Int
    /// Bytes/second across both directions, differenced between snapshots.
    public var netRateBytesPerSec: Double?
    public var blockRateBytesPerSec: Double?

    public init(name: String, cpuPercent: Double, memPercent: Double, memText: String, netText: String, blockText: String, pids: Int,
                netRateBytesPerSec: Double? = nil, blockRateBytesPerSec: Double? = nil) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.memText = memText
        self.netText = netText
        self.blockText = blockText
        self.pids = pids
        self.netRateBytesPerSec = netRateBytesPerSec
        self.blockRateBytesPerSec = blockRateBytesPerSec
    }
}

/// A host's resource snapshot: host CPU/mem/GPU plus every container's stats.
public struct HostResources: Sendable, Equatable {
    public var cores: Int
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var memUsedMB: Int
    public var memTotalMB: Int
    public var swapUsedMB: Int
    public var swapTotalMB: Int
    public var uptimeSeconds: Int
    public var disks: [DiskUsage]
    public var gpus: [GPUResources]
    public var containers: [String: ContainerResources]

    public init(cores: Int = 0, load1: Double = 0, load5: Double = 0, load15: Double = 0,
                memUsedMB: Int = 0, memTotalMB: Int = 0, swapUsedMB: Int = 0, swapTotalMB: Int = 0,
                uptimeSeconds: Int = 0, disks: [DiskUsage] = [], gpus: [GPUResources] = [], containers: [String: ContainerResources] = [:]) {
        self.cores = cores
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.memUsedMB = memUsedMB
        self.memTotalMB = memTotalMB
        self.swapUsedMB = swapUsedMB
        self.swapTotalMB = swapTotalMB
        self.uptimeSeconds = uptimeSeconds
        self.disks = disks
        self.gpus = gpus
        self.containers = containers
    }

    public var memPercent: Double {
        memTotalMB > 0 ? Double(memUsedMB) / Double(memTotalMB) * 100 : 0
    }

    public var swapPercent: Double {
        swapTotalMB > 0 ? Double(swapUsedMB) / Double(swapTotalMB) * 100 : 0
    }
}

/// Reads a host's resource use over one ssh connection. Fully read-only:
/// `docker stats --no-stream`, a few `/proc` reads and an optional `nvidia-smi`
/// query. It never changes a container or the host.
public enum ResourceProbe {
    public static func run(
        host: HostConfig,
        options: SSHOptions = SSHOptions(),
        timeoutSeconds: Int = 20
    ) async -> Result<HostResources, RemoteFailure> {
        let destination: SSHDestination
        do {
            destination = try SSHDestination(host.sshDestination)
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }
        let fmt = "{{.Name}}\\t{{.CPUPerc}}\\t{{.MemPerc}}\\t{{.MemUsage}}\\t{{.NetIO}}\\t{{.BlockIO}}\\t{{.PIDs}}"
        let script = """
        echo '@@host'
        nproc 2>/dev/null
        cat /proc/loadavg 2>/dev/null
        free -m 2>/dev/null | awk '/^Mem:/{print "mem "$3" "$2} /^Swap:/{print "swap "$3" "$2}'
        awk '{print "uptime "int($1)}' /proc/uptime 2>/dev/null
        echo '@@disk'
        df -Pk -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null | awk 'NR>1{print $3" "$2" "$6}'
        echo '@@gpu'
        command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null
        echo '@@containers'
        docker stats --no-stream --format '\(fmt)' 2>/dev/null
        echo '@@end'
        """
        let sshArgv = RemoteCommand.ssh(destination, options: options, allocateTTY: false, remote: script)
        let result: CommandResult
        do {
            result = try await CommandRunner.run(
                executable: RemoteCommand.sshExecutable,
                arguments: sshArgv,
                timeout: .seconds(timeoutSeconds)
            )
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }
        if let failure = RemoteFailure.classify(result) {
            return .failure(failure)
        }
        return .success(parse(result.stdoutText))
    }

    static func parse(_ text: String) -> HostResources {
        var resources = HostResources()
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@") { section = line; continue }
            if line.isEmpty { continue }
            switch section {
            case "@@host":
                let parts = line.split(separator: " ").map(String.init)
                if line.hasPrefix("mem "), parts.count == 3 {
                    resources.memUsedMB = Int(parts[1]) ?? 0
                    resources.memTotalMB = Int(parts[2]) ?? 0
                } else if line.hasPrefix("swap "), parts.count == 3 {
                    resources.swapUsedMB = Int(parts[1]) ?? 0
                    resources.swapTotalMB = Int(parts[2]) ?? 0
                } else if line.hasPrefix("uptime "), parts.count == 2 {
                    resources.uptimeSeconds = Int(parts[1]) ?? 0
                } else if parts.count == 1, let cores = Int(parts[0]) {
                    resources.cores = cores
                } else if parts.count >= 3, let l1 = Double(parts[0]) {
                    // /proc/loadavg: "3.40 3.27 3.04 2/1234 56789"
                    resources.load1 = l1
                    if let l5 = Double(parts[1]) { resources.load5 = l5 }
                    if let l15 = Double(parts[2]) { resources.load15 = l15 }
                }
            case "@@disk":
                let p = line.split(separator: " ").map(String.init)
                if p.count >= 3, let used = Int(p[0]), let total = Int(p[1]), total > 0 {
                    resources.disks.append(DiskUsage(mount: p[2...].joined(separator: " "), usedKB: used, totalKB: total))
                }
            case "@@gpu":
                if let gpu = parseGPU(line) { resources.gpus.append(gpu) }
            case "@@containers":
                if let container = parseContainer(line) { resources.containers[container.name] = container }
            default:
                break
            }
        }
        return resources
    }

    private static func parseGPU(_ line: String) -> GPUResources? {
        // "0, NVIDIA RTX, 45, 1234, 16384"
        let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count == 5, let index = Int(f[0]), let util = Double(f[2]), let used = Int(f[3]), let total = Int(f[4]) else { return nil }
        return GPUResources(index: index, name: f[1], utilizationPercent: util, memUsedMB: used, memTotalMB: total)
    }

    private static func parseContainer(_ line: String) -> ContainerResources? {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7 else { return nil }
        return ContainerResources(
            name: f[0],
            cpuPercent: percent(f[1]),
            memPercent: percent(f[2]),
            memText: f[3],
            netText: f[4],
            blockText: f[5],
            pids: Int(f[6]) ?? 0
        )
    }

    /// "207.12%" → 207.12
    private static func percent(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Parses a Docker-formatted size ("54.1GB", "578MB", "1.2kB", "12B",
    /// "3.4MiB") into bytes. Decimal units are base-1000; binary (…iB) base-1024.
    /// Used to difference two `docker stats` cumulative I/O figures into a rate.
    public static func parseBytes(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let digits = s.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let value = Double(digits) else { return nil }
        switch s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces) {
        case "", "B": return value
        case "kB", "KB": return value * 1_000
        case "MB": return value * 1_000_000
        case "GB": return value * 1_000_000_000
        case "TB": return value * 1_000_000_000_000
        case "KiB": return value * 1024
        case "MiB": return value * 1_048_576
        case "GiB": return value * 1_073_741_824
        case "TiB": return value * 1_099_511_627_776
        default: return nil
        }
    }

    /// Sums the two halves of a Docker "a / b" I/O pair into total bytes.
    public static func pairTotalBytes(_ pair: String) -> Double? {
        let halves = pair.components(separatedBy: " / ")
        let values = halves.compactMap { parseBytes($0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}
