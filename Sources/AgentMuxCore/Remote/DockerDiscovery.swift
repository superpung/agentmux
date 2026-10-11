import Foundation

/// A container found on a host by `docker ps` (read-only).
public struct DiscoveredContainer: Sendable, Equatable, Identifiable {
    public var id: String { fullID }
    public var fullID: String
    public var name: String
    public var image: String
    public var status: String
    public var running: Bool

    public init(fullID: String, name: String, image: String, status: String, running: Bool) {
        self.fullID = fullID
        self.name = name
        self.image = image
        self.status = status
        self.running = running
    }
}

/// Lists the containers on a host over one ssh connection. Read-only: it never
/// starts, stops or changes a container, and reads only name/image/status —
/// not `.Config.Env` or other sensitive fields.
public enum DockerDiscovery {
    public static func list(
        host: HostConfig,
        options: SSHOptions = SSHOptions(),
        includeStopped: Bool = false,
        timeoutSeconds: Int = 15
    ) async -> Result<[DiscoveredContainer], RemoteFailure> {
        let destination: SSHDestination
        do {
            destination = try SSHDestination(host.sshDestination)
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }
        // Tab-separated controlled fields; these never contain tabs/newlines.
        let format = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}"
        var argv = ["docker", "ps", "--no-trunc", "--format", format]
        if includeStopped { argv.append("--all") }
        let remote = ShellQuote.command(argv)
        let sshArgv = RemoteCommand.ssh(destination, options: options, allocateTTY: false, remote: remote)

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

    static func parse(_ text: String) -> [DiscoveredContainer] {
        text.split(separator: "\n").compactMap { line -> DiscoveredContainer? in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5 else { return nil }
            return DiscoveredContainer(
                fullID: String(fields[0]),
                name: String(fields[1]),
                image: String(fields[2]),
                status: String(fields[4]),
                running: fields[3] == "running"
            )
        }
    }
}
