import Foundation

/// On-demand read of the unified diff of one file in an agent's working tree
/// (`git diff HEAD -- <path>`). Read-only; it never writes, and it runs only
/// when the user opens a file's diff, never on the status refresh cycle. Output
/// is bounded on the remote so a large diff can't flood the channel.
public enum GitDiffProbe {
    public static func file(
        host: HostConfig, target: TargetConfig, cwd: String, path: String,
        options: SSHOptions = SSHOptions(), maxLines: Int = 1200, timeoutSeconds: Int = 20
    ) async -> Result<String, RemoteFailure> {
        let safeCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let safePath = path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        cd '\(safeCwd)' 2>/dev/null || { echo '@@norepo'; exit 0; }
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo '@@norepo'; exit 0; }
        git -c core.quotepath=false diff HEAD -- '\(safePath)' 2>/dev/null | head -n \(maxLines)
        """
        return (await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: timeoutSeconds))
            .map { $0.hasPrefix("@@norepo") ? "" : $0 }
    }
}
