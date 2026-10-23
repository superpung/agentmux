import Foundation

/// Per-file line churn from `git diff HEAD --numstat`: the path and its added /
/// removed line counts. A binary file reports -1 for both. Never file contents.
public struct GitFileStat: Sendable, Equatable, Hashable, Identifiable {
    public var path: String
    public var insertions: Int
    public var deletions: Int

    public init(path: String, insertions: Int, deletions: Int) {
        self.path = path
        self.insertions = insertions
        self.deletions = deletions
    }

    public var id: String { path }
    public var isBinary: Bool { insertions < 0 || deletions < 0 }
    public var churn: Int { max(0, insertions) + max(0, deletions) }
}

/// A read-only summary of the git working tree in an agent's directory. Counts,
/// the branch, and a per-file stat overview — never file contents.
public struct GitStatus: Sendable, Equatable {
    public var branch: String
    public var changedFiles: Int
    public var untracked: Int
    public var insertions: Int
    public var deletions: Int
    public var ahead: Int
    public var behind: Int
    public var files: [GitFileStat]

    public init(branch: String = "", changedFiles: Int = 0, untracked: Int = 0,
                insertions: Int = 0, deletions: Int = 0, ahead: Int = 0, behind: Int = 0,
                files: [GitFileStat] = []) {
        self.branch = branch
        self.changedFiles = changedFiles
        self.untracked = untracked
        self.insertions = insertions
        self.deletions = deletions
        self.ahead = ahead
        self.behind = behind
        self.files = files
    }

    public var isClean: Bool { changedFiles == 0 && untracked == 0 }
}

/// Reads the git status of an agent's working directory, inside its container.
/// Fully read-only (`git status` / `diff --shortstat` / `rev-list`); it never
/// reads file contents and never writes. Returns nil when the directory is not
/// a git work tree.
public enum GitStatusProbe {
    public static func run(
        host: HostConfig, target: TargetConfig, cwd: String,
        options: SSHOptions = SSHOptions(), timeoutSeconds: Int = 15
    ) async -> Result<GitStatus?, RemoteFailure> {
        let safeCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        cd '\(safeCwd)' 2>/dev/null || { echo '@@norepo'; exit 0; }
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo '@@norepo'; exit 0; }
        echo '@@git'
        printf 'branch %s\\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        git status --porcelain=v1 2>/dev/null | awk '/^\\?\\?/{u++} /^[^?]/{c++} END{printf "counts %d %d\\n", c+0, u+0}'
        git diff HEAD --shortstat 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i ~ /insertion/)ins=$(i-1); if($i ~ /deletion/)del=$(i-1)}} END{printf "diff %d %d\\n", ins+0, del+0}'
        ab=$(git rev-list --left-right --count @{upstream}...HEAD 2>/dev/null) && printf 'ab %s\\n' "$ab"
        echo '@@files'
        git -c core.quotepath=false diff HEAD --numstat 2>/dev/null | head -200
        """
        let result = await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: timeoutSeconds)
        return result.map { parse($0) }
    }

    static func parse(_ text: String) -> GitStatus? {
        if text.contains("@@norepo") { return nil }
        guard text.contains("@@git") else { return nil }
        var git = GitStatus()
        var inFiles = false
        for rawLine in text.split(separator: "\n") {
            if rawLine == "@@files" { inFiles = true; continue }
            if inFiles {
                // numstat: "<ins>\t<del>\t<path>"; "-" for a binary file.
                let cols = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard cols.count == 3 else { continue }
                let path = String(cols[2])
                guard !path.isEmpty else { continue }
                git.files.append(GitFileStat(path: path,
                                             insertions: Int(cols[0]) ?? -1,
                                             deletions: Int(cols[1]) ?? -1))
                continue
            }
            let f = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            switch f.first {
            case "branch": if f.count >= 2 { git.branch = f[1] }
            case "counts": if f.count >= 3 { git.changedFiles = Int(f[1]) ?? 0; git.untracked = Int(f[2]) ?? 0 }
            case "diff": if f.count >= 3 { git.insertions = Int(f[1]) ?? 0; git.deletions = Int(f[2]) ?? 0 }
            case "ab": if f.count >= 3 { git.behind = Int(f[1]) ?? 0; git.ahead = Int(f[2]) ?? 0 }
            default: break
            }
        }
        return git
    }
}
