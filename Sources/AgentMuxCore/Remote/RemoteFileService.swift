import Foundation

/// One entry in a remote directory listing.
public struct RemoteFileEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    /// True for a folder, including a symlink that points at one.
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int
    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, isSymlink: Bool = false, size: Int) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
    }
}

/// The previewable content of a remote file.
public enum RemoteFileContent: Sendable, Equatable {
    case text(String, truncated: Bool, byteCount: Int)
    case image(Data)
    case pdf(Data)
    case binary(byteCount: Int)
    case tooLarge(byteCount: Int)
    case empty
    /// The path is a folder, not a file.
    case directory
}

/// Read-only browsing and preview of files inside a target's container, over
/// the existing ssh→exec pipeline. It only ever reads: a one-level `find`
/// listing and a size-capped, base64-framed `head` of a file. It never writes
/// or changes anything on the host or in the container.
public enum RemoteFileService {
    public static let textByteCap = 512 * 1024
    public static let imageByteCap = 5 * 1024 * 1024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "heic", "ico"]

    /// Lists one directory level (no recursion), directories first then files,
    /// each sorted case-insensitively by name.
    public static func list(
        _ directory: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<[RemoteFileEntry], RemoteFailure> {
        let find = ShellQuote.command(["find", directory, "-mindepth", "1", "-maxdepth", "1",
                                       "-printf", #"%y\t%Y\t%s\t%f\n"#])
        let result = await RemoteScript.run("\(find) 2>/dev/null", host: host, target: target,
                                            options: options, timeoutSeconds: 15)
        return result.map { parseListing(directory, stripFraming($0)) }
    }

    /// Reads a file for preview: text (truncated past the cap), an image (under
    /// the cap), or a marker for binary / too-large / a folder.
    public static func read(
        _ path: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<RemoteFileContent, RemoteFailure> {
        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = imageExtensions.contains(ext)
        let isPDF = ext == "pdf"
        // Images / PDFs are read whole (up to the image cap); SVG is text but
        // needs the whole file to render, so it also gets the larger cap.
        let cap = (isImage || isPDF || ext == "svg") ? imageByteCap : textByteCap
        let qf = ShellQuote.command([path])
        let script = """
        if [ -d \(qf) ]; then printf '@@dir\\n'; else
        sz=$(stat -c %s \(qf) 2>/dev/null || echo -1)
        printf '@@size %s\\n' "$sz"
        head -c \(cap) \(qf) 2>/dev/null | base64 | tr -d '\\n'
        fi
        """
        let result = await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: 20,
                                            stdoutLimit: base64OutputLimit(cap))
        return result.flatMap { parseRead(stripFraming($0), isImage: isImage, isPDF: isPDF, cap: cap) }
    }

    public enum PathKind: Sendable, Equatable { case file, directory, missing }

    /// Whether `path` is a folder, something else, or nothing. Read-only.
    public static func kind(
        of path: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<PathKind, RemoteFailure> {
        let qf = ShellQuote.command([path])
        let script = "if [ -d \(qf) ]; then printf '@@dir\\n'; elif [ -e \(qf) ]; then printf '@@file\\n'; else printf '@@missing\\n'; fi"
        let result = await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: 15)
        return result.map { parseKind(stripFraming($0)) }
    }

    /// The largest file the one-shot (non-chunked) download will transfer.
    public static let downloadByteCap = 50 * 1024 * 1024

    /// Reads a whole file for saving to the Mac (up to `downloadByteCap`). Fully
    /// read-only — it never writes to the remote. An over-cap file fails with its
    /// size in the detail rather than transferring a huge payload in one shot.
    public static func download(
        _ path: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<Data, RemoteFailure> {
        let qf = ShellQuote.command([path])
        let script = """
        sz=$(stat -c %s \(qf) 2>/dev/null || echo -1)
        printf '@@size %s\\n' "$sz"
        if [ "$sz" -ge 0 ] && [ "$sz" -le \(downloadByteCap) ]; then base64 \(qf) 2>/dev/null | tr -d '\\n'; fi
        """
        let result = await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: 180,
                                            stdoutLimit: base64OutputLimit(downloadByteCap))
        return result.flatMap { parseDownload(stripFraming($0)) }
    }

    /// Stdout room for a script that prints `bytes` as base64 plus a few framing
    /// lines. Without it the runner's 4 MiB default cut off anything over ~3 MB.
    static func base64OutputLimit(_ bytes: Int) -> Int {
        (bytes + 2) / 3 * 4 + 64 * 1024
    }

    static func parseDownload(_ output: String) -> Result<Data, RemoteFailure> {
        var size = -1
        var b64 = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@size ") {
                size = Int(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? -1
            } else {
                b64 += line
            }
        }
        if size < 0 { return .failure(RemoteFailure(.remoteCommandFailed, detail: "file not found or unreadable")) }
        if size > downloadByteCap {
            let human = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: Int64(downloadByteCap), countStyle: .file)
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "file is \(human); too large to download (max \(limit))"))
        }
        guard let data = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "base64 decode failed"))
        }
        return .success(data)
    }

    public enum UploadResult: Sendable, Equatable { case written, alreadyExists }

    /// Writes a local file into the container at `path`. A remote write, gated in
    /// the UI by an explicit action. With `overwrite` false it refuses (returns
    /// `.alreadyExists`) rather than clobber an existing file, so an agent's file
    /// is never replaced without the user confirming. Capped at `downloadByteCap`.
    public static func upload(
        _ data: Data, to path: String, host: HostConfig, target: TargetConfig,
        overwrite: Bool, options: SSHOptions = SSHOptions()
    ) async -> Result<UploadResult, RemoteFailure> {
        if data.count > downloadByteCap {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(downloadByteCap), countStyle: .file)
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "file is larger than the \(limit) upload limit"))
        }
        let qf = ShellQuote.command([path])
        let guardLine = overwrite ? "" : "if [ -e \(qf) ]; then printf '@@exists\\n'; exit 0; fi"
        let script = """
        \(guardLine)
        if base64 -d > \(qf) <<'__AGENTMUX_B64__'
        \(data.base64EncodedString())
        __AGENTMUX_B64__
        then printf '@@ok\\n'; else printf '@@err\\n'; fi
        """
        let result = await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: 180)
        return result.flatMap { output in
            let text = stripFraming(output)
            if text.contains("@@exists") { return .success(.alreadyExists) }
            if text.contains("@@ok") { return .success(.written) }
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(RemoteFailure(.remoteCommandFailed, detail: detail.isEmpty ? "upload failed" : detail))
        }
    }

    /// Removes a file from the remote. A destructive write, gated in the UI by a
    /// confirmation. It refuses a directory (never recurses), so a mis-click on a
    /// folder cannot wipe a tree.
    public static func delete(
        _ path: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<Void, RemoteFailure> {
        let qf = ShellQuote.command([path])
        let script = "if [ -d \(qf) ] && [ ! -L \(qf) ]; then printf '@@isdir\\n'; else rm -f \(qf) && printf '@@ok\\n' || printf '@@err\\n'; fi"
        let result = await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: 15)
        return result.flatMap { output in
            let text = stripFraming(output)
            if text.contains("@@ok") { return .success(()) }
            if text.contains("@@isdir") { return .failure(RemoteFailure(.remoteCommandFailed, detail: "that is a directory")) }
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(RemoteFailure(.remoteCommandFailed, detail: detail.isEmpty ? "delete failed" : detail))
        }
    }

    /// The outcome of a remote write that never replaces an existing path.
    public enum NoClobberResult: Sendable, Equatable { case done, alreadyExists }

    /// Creates an empty file. Refuses (`.alreadyExists`) when anything is at
    /// `path`, so an existing file is never truncated.
    public static func createFile(
        _ path: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<NoClobberResult, RemoteFailure> {
        let result = await RemoteScript.run(createFileScript(path), host: host, target: target,
                                            options: options, timeoutSeconds: 15)
        return result.flatMap(parseNoClobber)
    }

    /// Creates one directory (no parents). Refuses when anything is at `path`.
    /// Unlike `makeDirectory`, an existing folder is reported, not reused.
    public static func createDirectory(
        _ path: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<NoClobberResult, RemoteFailure> {
        let result = await RemoteScript.run(createDirectoryScript(path), host: host, target: target,
                                            options: options, timeoutSeconds: 15)
        return result.flatMap(parseNoClobber)
    }

    /// Renames (moves) a file or folder. Refuses when `newPath` exists, so a
    /// rename never replaces another entry or moves into an existing folder.
    public static func rename(
        _ path: String, to newPath: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<NoClobberResult, RemoteFailure> {
        let result = await RemoteScript.run(renameScript(path, to: newPath), host: host, target: target,
                                            options: options, timeoutSeconds: 15)
        return result.flatMap(parseNoClobber)
    }

    /// Removes an empty folder (`rmdir`). Never recurses: a folder with
    /// anything in it fails with the remote's message. A symlink to a folder
    /// is removed as a link, leaving its target untouched.
    public static func removeDirectory(
        _ path: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<Void, RemoteFailure> {
        let result = await RemoteScript.run(removeDirectoryScript(path), host: host, target: target,
                                            options: options, timeoutSeconds: 15)
        return result.flatMap { output in
            parseNoClobber(output).flatMap { outcome in
                outcome == .done ? .success(()) : .failure(RemoteFailure(.remoteCommandFailed, detail: "unexpected response"))
            }
        }
    }

    // Scripts for the no-clobber writes (POSIX sh; run locally by the tests).
    // Each prints one marker that `parseNoClobber` reads.

    /// noclobber (`set -C`) also covers a file appearing between the check and
    /// the redirection, which then fails instead of truncating it.
    static func createFileScript(_ path: String) -> String {
        let qf = ShellQuote.command([path])
        return """
        if [ -e \(qf) ] || [ -L \(qf) ]; then printf '@@exists\\n'
        elif err=$( (set -C; : > \(qf)) 2>&1 ); then printf '@@ok\\n'
        else printf '@@err %s\\n' "$err"; fi
        """
    }

    static func createDirectoryScript(_ path: String) -> String {
        let qd = ShellQuote.command([path])
        return """
        if [ -e \(qd) ] || [ -L \(qd) ]; then printf '@@exists\\n'
        elif err=$(mkdir -- \(qd) 2>&1); then printf '@@ok\\n'
        else printf '@@err %s\\n' "$err"; fi
        """
    }

    static func renameScript(_ path: String, to newPath: String) -> String {
        let qs = ShellQuote.command([path])
        let qd = ShellQuote.command([newPath])
        return """
        if [ ! -e \(qs) ] && [ ! -L \(qs) ]; then printf '@@missing\\n'
        elif [ -e \(qd) ] || [ -L \(qd) ]; then printf '@@exists\\n'
        elif err=$(mv -- \(qs) \(qd) 2>&1); then printf '@@ok\\n'
        else printf '@@err %s\\n' "$err"; fi
        """
    }

    static func removeDirectoryScript(_ path: String) -> String {
        let qd = ShellQuote.command([path])
        return """
        if [ -L \(qd) ]; then
          if err=$(rm -f -- \(qd) 2>&1); then printf '@@ok\\n'; else printf '@@err %s\\n' "$err"; fi
        elif [ ! -d \(qd) ]; then printf '@@err not a folder\\n'
        elif err=$(rmdir -- \(qd) 2>&1); then printf '@@ok\\n'
        else printf '@@err %s\\n' "$err"; fi
        """
    }

    /// Why a name can't be used for a new or renamed entry.
    public enum NameProblem: Sendable, Equatable {
        case empty
        /// "." or "..".
        case reserved
        case slash
        /// Line breaks would split the entry across lines of the listing.
        case lineBreak
        /// Over the 255-byte limit of Linux file systems.
        case tooLong
    }

    /// Checks a single path component typed by the user. nil means usable.
    public static func nameProblem(_ name: String) -> NameProblem? {
        if name.isEmpty { return .empty }
        if name == "." || name == ".." { return .reserved }
        if name.contains("/") { return .slash }
        if name.contains(where: \.isNewline) || name.unicodeScalars.contains("\0") { return .lineBreak }
        if name.utf8.count > 255 { return .tooLong }
        return nil
    }

    /// Why a local item can't be uploaded, or nil when it can.
    public enum UploadRefusal: Sendable, Equatable {
        case folder
        /// A FIFO, socket or device: reading it could block or never end.
        case notAFile
        case unusableName
        case tooLarge
    }

    /// The upload policy shared by the open panel and drag-and-drop: regular
    /// files only, with a name the listing can show, up to `downloadByteCap`.
    public static func uploadRefusal(name: String, isDirectory: Bool, isRegularFile: Bool, size: Int) -> UploadRefusal? {
        if isDirectory { return .folder }
        if !isRegularFile { return .notAFile }
        if nameProblem(name) != nil { return .unusableName }
        if size > downloadByteCap { return .tooLarge }
        return nil
    }

    /// `name` inside `directory`, joined the way listings build entry paths.
    public static func path(_ name: String, in directory: String) -> String {
        (directory.hasSuffix("/") ? directory : directory + "/") + name
    }

    /// Best-effort cleanup: deletes regular files in `directory` last modified
    /// more than `days` ago. Used to keep the paste-image cache small; it never
    /// reports failure to the caller.
    public static func pruneOld(
        _ directory: String, olderThanDays days: Int, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async {
        let qd = ShellQuote.command([directory])
        _ = await RemoteScript.run(
            "find \(qd) -maxdepth 1 -type f -mtime +\(max(0, days - 1)) -delete 2>/dev/null; true",
            host: host, target: target, options: options, timeoutSeconds: 15
        )
    }

    /// Creates a directory (and parents) in the container — a write like upload,
    /// used by the launch flow / directory picker when the user makes a new
    /// folder. `mkdir -p` is idempotent, so an existing path is a no-op.
    public static func makeDirectory(
        _ path: String, host: HostConfig, target: TargetConfig, options: SSHOptions = SSHOptions()
    ) async -> Result<Void, RemoteFailure> {
        let script = "mkdir -p \(ShellQuote.command([path])) 2>&1"
        return await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: 15)
            .flatMap { output in
                let message = stripFraming(output).trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? .success(()) : .failure(RemoteFailure(.remoteCommandFailed, detail: message))
            }
    }

    // MARK: Parsing (pure; unit-tested)

    /// `RemoteCommand.script` prepends an `@@container …` line (from a
    /// `docker inspect`) for container targets. Drop any such framing lines
    /// before parsing the script's own output.
    static func stripFraming(_ output: String) -> String {
        guard output.contains("@@container ") else { return output }
        return output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("@@container ") }
            .joined(separator: "\n")
    }

    /// Reads the marker a no-clobber write prints: `@@ok`, `@@exists`,
    /// `@@missing` or `@@err <message>` (the message may span lines).
    static func parseNoClobber(_ output: String) -> Result<NoClobberResult, RemoteFailure> {
        let lines = stripFraming(output).split(separator: "\n", omittingEmptySubsequences: true)
        guard let index = lines.firstIndex(where: { $0.hasPrefix("@@") }) else {
            let detail = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return .failure(RemoteFailure(.remoteCommandFailed, detail: detail.isEmpty ? "no response" : detail))
        }
        let marker = lines[index]
        if marker == "@@ok" { return .success(.done) }
        if marker == "@@exists" { return .success(.alreadyExists) }
        if marker == "@@missing" { return .failure(RemoteFailure(.remoteCommandFailed, detail: "it no longer exists")) }
        let rest = ([marker.dropFirst("@@err".count)] + lines[(index + 1)...])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return .failure(RemoteFailure(.remoteCommandFailed, detail: rest.isEmpty ? "the remote command failed" : rest))
    }

    static func parseListing(_ directory: String, _ output: String) -> [RemoteFileEntry] {
        var entries: [RemoteFileEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let name = String(fields[3])
            if name.isEmpty || name == "." || name == ".." { continue }
            let isDir = fields[0] == "d" || (fields[0] == "l" && fields[1] == "d")
            entries.append(RemoteFileEntry(name: name, path: path(name, in: directory), isDirectory: isDir,
                                           isSymlink: fields[0] == "l", size: Int(fields[2]) ?? 0))
        }
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func parseKind(_ output: String) -> PathKind {
        let lines = output.split(separator: "\n")
        if lines.contains("@@dir") { return .directory }
        if lines.contains("@@file") { return .file }
        return .missing
    }

    static func parseRead(_ output: String, isImage: Bool, isPDF: Bool = false, cap: Int) -> Result<RemoteFileContent, RemoteFailure> {
        if output.split(separator: "\n").first == "@@dir" { return .success(.directory) }
        guard let newline = output.firstIndex(of: "\n") else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "unreadable response"))
        }
        let header = output[..<newline]
        guard header.hasPrefix("@@size "), let size = Int(header.dropFirst("@@size ".count).trimmingCharacters(in: .whitespaces)) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "bad response header"))
        }
        if size < 0 { return .failure(RemoteFailure(.remoteCommandFailed, detail: "not a readable file")) }
        if size == 0 { return .success(.empty) }

        let b64 = output[output.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: b64) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "base64 decode failed"))
        }
        if isPDF {
            return size > cap ? .success(.tooLarge(byteCount: size)) : .success(.pdf(data))
        }
        if isImage {
            return size > cap ? .success(.tooLarge(byteCount: size)) : .success(.image(data))
        }
        // A NUL byte in the sample is the binary heuristic; otherwise decode
        // UTF-8 leniently so a byte-truncated tail doesn't fail the whole read.
        if data.contains(0) { return .success(.binary(byteCount: size)) }
        return .success(.text(String(decoding: data, as: UTF8.self), truncated: size > cap, byteCount: size))
    }
}
