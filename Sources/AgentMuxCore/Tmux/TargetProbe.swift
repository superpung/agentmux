import Foundation

/// Runs one read-only inventory of a target: a single ssh connection that
/// inspects the container (if any) and runs `InventoryProbe` inside it.
public enum TargetProbe {
    public static func run(
        host: HostConfig,
        target: TargetConfig,
        options: SSHOptions = SSHOptions(),
        timeoutSeconds: Int = 20
    ) async -> Result<InventorySnapshot, RemoteFailure> {
        let destination: SSHDestination
        let context: ExecutionContext
        do {
            destination = try SSHDestination(host.sshDestination)
            context = try target.executionContext()
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }

        let nonce = makeNonce()
        let argv = RemoteCommand.ssh(
            destination,
            options: options,
            allocateTTY: false,
            remote: RemoteCommand.script(in: context, timeoutSeconds: timeoutSeconds)
        )
        let result: CommandResult
        do {
            result = try await CommandRunner.run(
                executable: RemoteCommand.sshExecutable,
                arguments: argv,
                stdin: Data(InventoryProbe.script(tmux: context.tmux, nonce: nonce).utf8),
                // Leave room for connection setup on top of the remote limit.
                timeout: .seconds(timeoutSeconds + options.connectTimeoutSeconds + 5)
            )
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }

        // `timeout` inside the target exits with 124.
        if result.exitStatus == 124 {
            return .failure(RemoteFailure(.commandTimeout, detail: "remote time limit reached"))
        }
        if let failure = RemoteFailure.classify(result) {
            return .failure(failure)
        }
        do {
            return try .success(InventoryProbe.parse(result.stdoutText, nonce: nonce))
        } catch let failure as RemoteFailure {
            return .failure(failure)
        } catch {
            return .failure(RemoteFailure(.protocolDesync, detail: "\(error)"))
        }
    }

    static func makeNonce() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< 16).map { _ in alphabet.randomElement()! })
    }
}
