import Foundation

/// How a file is read for its preview, decided by its name.
public enum PreviewFormat: Sendable, Equatable {
    /// Text, or a binary file's first bytes (up to a cap that depends on
    /// the kind: SVGs and notebooks are read whole).
    case text
    case image
    case pdf
    /// Read whole, for the system's viewer or a player: Office and iWork
    /// documents, audio and video.
    case document(DocumentKind)
    /// One compressed file (`app.log.gz`): decompressed on the remote with
    /// `tool`, and shown as the file inside.
    case compressed(tool: String)
    /// A zip or tar archive: its listing.
    case archive

    public enum DocumentKind: Sendable, Equatable {
        case word, spreadsheet, presentation, iWork, audio, video
    }

    public static func of(_ path: String) -> PreviewFormat {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if archiveSuffixes.contains(where: { name.hasSuffix("." + $0) }) { return .archive }
        if let tool = compressionTools[ext] { return .compressed(tool: tool) }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if let kind = documentKinds[ext] { return .document(kind) }
        return .text
    }

    /// The name of the file a compressed file holds (`app.log.gz` →
    /// `app.log`); any other name as it is.
    public static func innerName(_ path: String) -> String {
        guard case .compressed = of(path) else { return path }
        return (path as NSString).deletingPathExtension
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "heic", "ico"]

    static let compressionTools = ["gz": "gzip", "bz2": "bzip2", "xz": "xz"]

    static let archiveSuffixes = ["zip", "jar", "war", "whl", "tar", "tgz", "tbz", "tbz2", "txz",
                                  "tar.gz", "tar.bz2", "tar.xz"]

    static let documentKinds: [String: DocumentKind] = {
        var kinds: [String: DocumentKind] = [:]
        for ext in ["docx", "docm", "dotx", "doc", "odt"] { kinds[ext] = .word }
        for ext in ["xlsx", "xlsm", "xltx", "xls"] { kinds[ext] = .spreadsheet }
        for ext in ["pptx", "pptm", "ppsx", "potx", "ppt", "pps"] { kinds[ext] = .presentation }
        for ext in ["pages", "numbers", "key"] { kinds[ext] = .iWork }
        for ext in ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"] { kinds[ext] = .audio }
        for ext in ["mp4", "m4v", "mov"] { kinds[ext] = .video }
        return kinds
    }()
}

/// One entry of an archive's listing.
public struct ArchiveEntry: Sendable, Equatable {
    /// Its path in the archive; a folder ends in `/`.
    public var name: String
    public var size: Int
    /// `yyyy-MM-dd HH:mm`, as the archive records it.
    public var modified: String

    public init(name: String, size: Int, modified: String) {
        self.name = name
        self.size = size
        self.modified = modified
    }
}
