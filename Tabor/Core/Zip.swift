import Foundation
#if canImport(Compression)
import Compression
#endif

public enum ZipError: Error, Equatable {
    case notAZip
    case corrupt
    case tooLarge
    case unsupported(method: UInt16)
    case missing(String)
}

/// Minimal ZIP writer for backups. Entries are stored, not deflated (photos are already
/// compressed), and streamed to disk one at a time so a big book never sits in memory.
public final class ZipWriter {
    private let handle: FileHandle
    private var central = Data()
    private var entries = 0
    private var offset: UInt64 = 0

    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }

    public func add(path: String, data: Data, modified: Date = Date()) throws {
        let name = Data(path.utf8)
        guard data.count < 0xFFFF_FFFF, offset + UInt64(data.count) < 0xFFFF_FFFF, entries < 0xFFFF else {
            throw ZipError.tooLarge
        }
        let crc = CRC32.checksum(data)
        let (time, date) = Self.dosDateTime(modified)

        var local = Data()
        local.le32(0x0403_4b50)
        local.le16(20) // version needed
        local.le16(0x0800) // UTF-8 names
        local.le16(0) // stored
        local.le16(time)
        local.le16(date)
        local.le32(crc)
        local.le32(UInt32(data.count))
        local.le32(UInt32(data.count))
        local.le16(UInt16(name.count))
        local.le16(0)
        local.append(name)

        var entry = Data()
        entry.le32(0x0201_4b50)
        entry.le16(20) // version made by
        entry.le16(20)
        entry.le16(0x0800)
        entry.le16(0)
        entry.le16(time)
        entry.le16(date)
        entry.le32(crc)
        entry.le32(UInt32(data.count))
        entry.le32(UInt32(data.count))
        entry.le16(UInt16(name.count))
        entry.le16(0) // extra
        entry.le16(0) // comment
        entry.le16(0) // disk
        entry.le16(0) // internal attributes
        entry.le32(0) // external attributes
        entry.le32(UInt32(offset))
        entry.append(name)

        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)
        offset += UInt64(local.count + data.count)
        central.append(entry)
        entries += 1
    }

    public func finish() throws {
        guard offset + UInt64(central.count) < 0xFFFF_FFFF else { throw ZipError.tooLarge }
        var end = Data()
        end.le32(0x0605_4b50)
        end.le16(0)
        end.le16(0)
        end.le16(UInt16(entries))
        end.le16(UInt16(entries))
        end.le32(UInt32(central.count))
        end.le32(UInt32(offset))
        end.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }

    static func dosDateTime(_ d: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let time = (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2
        let date = max((c.year ?? 1980) - 1980, 0) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: date))
    }
}

/// Reads stored and deflated entries — our own backups, or the same folder re-zipped by Finder.
public struct ZipReader {
    public struct Entry: Sendable {
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    public let entries: [String: Entry]
    private let data: Data

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data raw: Data) throws {
        // Re-base to zero so offsets from the file index straight into it.
        let data = raw.startIndex == 0 ? raw : Data(raw)
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZip }
        // The end-of-central-directory record sits in the last 64 KiB (after an optional comment).
        var eocd: Int?
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 0xFFFF)
        while i >= floor {
            if data.u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw ZipError.notAZip }
        let count = Int(data.u16(eocd + 10))
        var p = Int(data.u32(eocd + 16))
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(p) == 0x0201_4b50 else { throw ZipError.corrupt }
            let nameLen = Int(data.u16(p + 28)), extraLen = Int(data.u16(p + 30)), commentLen = Int(data.u16(p + 32))
            guard p + 46 + nameLen <= data.count else { throw ZipError.corrupt }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            let csize = data.u32(p + 20), size = data.u32(p + 24), local = data.u32(p + 42)
            guard csize != 0xFFFF_FFFF, size != 0xFFFF_FFFF, local != 0xFFFF_FFFF else { throw ZipError.tooLarge }
            entries[name] = Entry(method: data.u16(p + 10), crc: data.u32(p + 16), compressedSize: Int(csize),
                                  size: Int(size), localOffset: Int(local))
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = entries
    }

    public func contains(_ path: String) -> Bool { entries[path] != nil }

    /// Finds `name` at the root or one folder down (Finder wraps a zipped folder in its name).
    public func path(endingWith name: String) -> String? {
        if entries[name] != nil { return name }
        return entries.keys.filter { $0.hasSuffix("/" + name) && !$0.hasPrefix("__MACOSX/") }
            .min { $0.count < $1.count }
    }

    public func read(_ path: String) throws -> Data {
        guard let e = entries[path] else { throw ZipError.missing(path) }
        let h = e.localOffset
        guard h + 30 <= data.count, data.u32(h) == 0x0403_4b50 else { throw ZipError.corrupt }
        let start = h + 30 + Int(data.u16(h + 26)) + Int(data.u16(h + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt }
        let raw = data[start..<(start + e.compressedSize)]
        let out: Data
        switch e.method {
        case 0: out = Data(raw)
        case 8: out = try Self.inflate(Data(raw), size: e.size)
        default: throw ZipError.unsupported(method: e.method)
        }
        guard out.count == e.size, CRC32.checksum(out) == e.crc else { throw ZipError.corrupt }
        return out
    }

    static func inflate(_ src: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        #if canImport(Compression)
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt }
        return out
        #else
        throw ZipError.unsupported(method: 8)
        #endif
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func le32(_ v: UInt32) { (0..<4).forEach { append(UInt8((v >> (8 * $0)) & 0xFF)) } }
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[i + $1]) << (8 * $1) } }
}
