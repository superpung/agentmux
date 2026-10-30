import CryptoKit
import Foundation

/// Copies of remote files kept on the Mac so a local app can open them. Each
/// copy has a folder of its own, named for its target and remote path, and
/// keeps the remote file's name, so the app shows that name and two files
/// called the same never meet. Copies are read-only: an app saves a changed
/// copy somewhere else, and nothing is written back to the remote.
public struct LocalCopies: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Caches/AgentMux/Opened`.
    public static var standard: LocalCopies {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return LocalCopies(root: caches.appendingPathComponent("AgentMux/Opened", isDirectory: true))
    }

    /// Where the copy of `path` in `target` lives.
    public func url(for path: String, target: String) -> URL {
        let digest = SHA256.hash(data: Data("\(target)\n\(path)".utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = (path as NSString).lastPathComponent
        return root.appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(name.isEmpty || name == "/" ? "file" : name)
    }

    /// Stores `data` as the copy of `path` and returns its URL. A copy that
    /// already holds `data` is left in place (an app may have it open) and
    /// only marked as used now; otherwise it is replaced.
    @discardableResult
    public func store(_ data: Data, for path: String, target: String) throws -> URL {
        let fm = FileManager.default
        let url = url(for: path, target: target)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: url), existing == data {
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }

    /// Deletes copies not stored or opened in the last `days` days.
    public func prune(olderThanDays days: Int, now: Date = Date()) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            if newest.map({ $0 < cutoff }) ?? true {
                try? fm.removeItem(at: folder)
            }
        }
    }
}
