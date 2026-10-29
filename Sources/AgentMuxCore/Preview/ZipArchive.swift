import Compression
import Foundation

/// The files in a ZIP archive held in memory: stored or deflated, without
/// ZIP64. Enough for the XML inside Office documents.
public struct ZipArchive: Sendable {
    private let data: Data
    private let entries: [String: Entry]

    private struct Entry: Sendable {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeader: Int
    }

    /// The largest file this will inflate.
    static let sizeCap = 256 * 1024 * 1024

    public init?(_ data: Data) {
        let data = Data(data) // Indices from 0.
        self.data = data
        // The end-of-central-directory record, behind at most a 64 KB comment.
        let minimum = max(0, data.count - 22 - 0xFFFF)
        var end: Int?
        var at = data.count - 22
        while at >= minimum {
            if data.u32(at) == 0x0605_4B50 { end = at; break }
            at -= 1
        }
        guard let end else { return nil }
        let count = Int(data.u16(end + 10))
        var offset = Int(data.u32(end + 16))
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x0201_4B50 else { return nil }
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            guard offset + 46 + nameLength <= data.count else { return nil }
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: data.u16(offset + 10), compressedSize: Int(data.u32(offset + 20)),
                                  size: Int(data.u32(offset + 24)), localHeader: Int(data.u32(offset + 42)))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public var names: [String] { Array(entries.keys) }

    /// A file's contents, or nil if it is missing, damaged or compressed in
    /// a way this does not read.
    public func file(_ name: String) -> Data? {
        guard let entry = entries[name], entry.size <= Self.sizeCap else { return nil }
        let header = entry.localHeader
        guard header + 30 <= data.count, data.u32(header) == 0x0403_4B50 else { return nil }
        let start = header + 30 + Int(data.u16(header + 26)) + Int(data.u16(header + 28))
        guard start + entry.compressedSize <= data.count else { return nil }
        let packed = data[start..<(start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(packed)
        case 8:
            guard entry.size > 0 else { return Data() }
            guard !packed.isEmpty else { return nil }
            var out = Data(count: entry.size)
            let written = out.withUnsafeMutableBytes { dst in
                packed.withUnsafeBytes { src in
                    // COMPRESSION_ZLIB is raw DEFLATE, as ZIP stores it.
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            return written == entry.size ? out : nil
        default:
            return nil
        }
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= count else { return 0 }
        return UInt16(self[at]) | UInt16(self[at + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }
}
