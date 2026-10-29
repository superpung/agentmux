import Compression
import Foundation

/// The files in a ZIP archive held in memory: stored or deflated, without
/// ZIP64. Enough for the XML inside Office documents.
public struct ZipArchive: Sendable {
    private let data: Data
    private let entries: [String: Entry]
    /// The files' names in the order the archive lists them.
    public let orderedNames: [String]

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
        var ordered: [String] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x0201_4B50 else { return nil }
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            guard offset + 46 + nameLength <= data.count else { return nil }
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: data.u16(offset + 10), compressedSize: Int(data.u32(offset + 20)),
                                  size: Int(data.u32(offset + 24)), localHeader: Int(data.u32(offset + 42)))
            ordered.append(name)
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
        orderedNames = ordered
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

/// Writes a ZIP archive of stored (uncompressed) files, enough for a local
/// copy that only a viewer reads.
public struct ZipWriter: Sendable {
    private var body = Data()
    private var directory = Data()
    private var count = 0

    public init() {}

    public mutating func add(_ name: String, _ contents: Data) {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(contents)
        let offset = UInt32(body.count)
        // Version 2.0, UTF-8 names, stored, dated 1980-01-01.
        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(0x0800); local.le16(0)
        local.le16(0); local.le16(0x21); local.le32(crc)
        local.le32(UInt32(contents.count)); local.le32(UInt32(contents.count))
        local.le16(UInt16(nameBytes.count)); local.le16(0)
        body += local + nameBytes + contents
        var central = Data()
        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0)
        central.le16(0); central.le16(0x21); central.le32(crc)
        central.le32(UInt32(contents.count)); central.le32(UInt32(contents.count))
        central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(0); central.le32(offset)
        directory += central + nameBytes
        count += 1
    }

    public func finish() -> Data {
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(directory.count)); end.le32(UInt32(body.count)); end.le16(0)
        return body + directory + end
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 0xFFFF)); le16(UInt16(value >> 16)) }

    func u16(_ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= count else { return 0 }
        return UInt16(self[at]) | UInt16(self[at + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }
}
