import Foundation

/// Runs a `sh` script inside an execution context over one non-interactive
/// ssh connection and returns its stdout.
public enum RemoteScript {
    public static func run(
        _ script: String,
        destination: SSHDestination,
        context: ExecutionContext,
        options: SSHOptions = SSHOptions(),
        timeoutSeconds: Int = 20,
        stdoutLimit: Int = 4 << 20
    ) async -> Result<String, RemoteFailure> {
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
                stdin: Data(script.utf8),
                // Leave room for connection setup on top of the remote limit.
                timeout: .seconds(timeoutSeconds + options.connectTimeoutSeconds + 5),
                stdoutLimit: stdoutLimit
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
        return .success(result.stdoutText)
    }

    public static func run(
        _ script: String,
        host: HostConfig,
        target: TargetConfig,
        options: SSHOptions = SSHOptions(),
        timeoutSeconds: Int = 20,
        stdoutLimit: Int = 4 << 20
    ) async -> Result<String, RemoteFailure> {
        do {
            return try await run(
                script,
                destination: SSHDestination(host.sshDestination),
                context: target.executionContext(),
                options: options,
                timeoutSeconds: timeoutSeconds,
                stdoutLimit: stdoutLimit
            )
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }
    }
}
