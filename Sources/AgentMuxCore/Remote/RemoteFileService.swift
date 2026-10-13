import Foundation

/// One entry in a remote directory listing.
public struct RemoteFileEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int
    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
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
    /// the cap), or a marker for binary / too-large.
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
        sz=$(stat -c %s \(qf) 2>/dev/null || echo -1)
        printf '@@size %s\\n' "$sz"
        head -c \(cap) \(qf) 2>/dev/null | base64 | tr -d '\\n'
        """
        let result = await RemoteScript.run(script, host: host, target: target, options: options, timeoutSeconds: 20)
        return result.flatMap { parseRead(stripFraming($0), isImage: isImage, isPDF: isPDF, cap: cap) }
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

    static func parseListing(_ directory: String, _ output: String) -> [RemoteFileEntry] {
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        var entries: [RemoteFileEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let name = String(fields[3])
            if name.isEmpty || name == "." || name == ".." { continue }
            let isDir = fields[0] == "d" || (fields[0] == "l" && fields[1] == "d")
            entries.append(RemoteFileEntry(name: name, path: base + name,
                                           isDirectory: isDir, size: Int(fields[2]) ?? 0))
        }
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func parseRead(_ output: String, isImage: Bool, isPDF: Bool = false, cap: Int) -> Result<RemoteFileContent, RemoteFailure> {
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
