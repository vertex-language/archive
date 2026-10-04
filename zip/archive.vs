package zip

import (
    "compress/flate"
    "fs"
    "io"
)

/// Archive reads a ZIP file where it lies on disk: only the central
/// directory is loaded, and each entry is streamed from the file as it
/// is read, so an archive (and any entry in it) can be far larger than
/// memory. ZIP64 archives, entries and offsets past 4 GiB, are read too.
///
///     let a = try zip.Archive.Open("image.zip")
///     defer { a.Close() }
///     var r = try a.Open(a.Find("system.img")!)
///     while try r.Read(into: &buf) > 0 { … }   // CRC-32 checked at the end
///
/// Reader is the in-memory equivalent, for archives already in bytes.
public final class Archive {
    public let Handle: fs.File
    /// The entries, in central-directory order.
    public private(set) var Files: [FileHeader] = []
    public private(set) var Comment: string = ""
    /// The file's size in bytes.
    public let Size: int64

    /// Opens the archive at `path`.
    public static func Open(_ path: string) throws -> Archive {
        try Archive(try fs.Open(fs.Path(path)))
    }

    /// Reads the central directory of the archive in `file`, which the
    /// Archive then owns (Close closes it).
    public init(_ file: fs.File) throws {
        Handle = file
        Size = try file.Metadata().Size
        try readDirectory()
    }

    public func Close() {
        try? Handle.Close()
    }

    /// The entry called `name`.
    public func Find(_ name: string) -> FileHeader? {
        for f in Files where f.Name == name { return f }
        return nil
    }

    /// A reader of `entry`'s uncompressed bytes. It throws at the end if
    /// what came out is not the size and CRC-32 the directory gives.
    public func Open(_ entry: FileHeader) throws -> EntryReader {
        let local = try bytes(at: entry.LocalHeaderOffset, count: 30)
        if readU32LE(local, 0) != 0x04034B50 {
            throw ZipError.badZip("invalid local file header signature at offset \(entry.LocalHeaderOffset)")
        }
        let start = entry.LocalHeaderOffset + 30 + int64(readU16LE(local, 26)) + int64(readU16LE(local, 28))
        if start + entry.CompressedSize > Size {
            throw ZipError.unexpectedEOF
        }
        return EntryReader(entry, Section(self, start, entry.CompressedSize))
    }

    /// `count` bytes at `offset`, all of them or unexpectedEOF.
    func bytes(at offset: int64, count: int) throws -> [uint8] {
        if offset < 0 || offset + int64(count) > Size { throw ZipError.unexpectedEOF }
        var b = [uint8](repeating: 0, count: count)
        var got = 0
        while got < count {
            var part = [uint8](repeating: 0, count: count - got)
            let n = try Handle.Read(into: &part, at: offset + int64(got))
            if n == 0 { throw ZipError.unexpectedEOF }
            for i in 0..<n { b[got + i] = part[i] }
            got += n
        }
        return b
    }

    func readDirectory() throws {
        if Size < 22 {
            throw ZipError.badZip("archive smaller than minimum zip size (22 bytes)")
        }
        // The end of central directory record is in the last 64 KiB + 22.
        let tailLen = int(min(Size, 65557))
        let tailAt = Size - int64(tailLen)
        let tail = try bytes(at: tailAt, count: tailLen)
        var eocd = -1
        var i = tailLen - 22
        while i >= 0 {
            if readU32LE(tail, i) == 0x06054B50 {
                eocd = i
                break
            }
            i -= 1
        }
        if eocd < 0 {
            throw ZipError.badZip("end of central directory record not found")
        }
        var entries = int64(readU16LE(tail, eocd + 10))
        var cdSize = int64(readU32LE(tail, eocd + 12))
        var cdOffset = int64(readU32LE(tail, eocd + 16))
        let commentLen = int(readU16LE(tail, eocd + 20))
        if commentLen > 0 && eocd + 22 + commentLen <= tailLen {
            Comment = string(decoding: Array(tail[(eocd + 22)..<(eocd + 22 + commentLen)]), as: UTF8.self)
        }
        // ZIP64: a locator just before the record points at the ZIP64 end
        // of central directory record, which has the full-width fields.
        if eocd >= 20 && readU32LE(tail, eocd - 20) == 0x07064B50 {
            let at = int64(readU64LE(tail, eocd - 20 + 8))
            let z = try bytes(at: at, count: 56)
            if readU32LE(z, 0) != 0x06064B50 {
                throw ZipError.badZip("invalid zip64 end of central directory record at \(at)")
            }
            entries = int64(readU64LE(z, 32))
            cdSize = int64(readU64LE(z, 40))
            cdOffset = int64(readU64LE(z, 48))
        }
        if cdOffset < 0 || cdSize < 0 || cdOffset + cdSize > Size {
            throw ZipError.badZip("central directory extends beyond file")
        }
        let cd = try bytes(at: cdOffset, count: int(cdSize))
        var cur = 0
        var n: int64 = 0
        while n < entries {
            if cur + 46 > cd.count { throw ZipError.unexpectedEOF }
            if readU32LE(cd, cur) != 0x02014B50 {
                throw ZipError.badZip("invalid central directory signature at offset \(cdOffset + int64(cur))")
            }
            let rawMethod = readU16LE(cd, cur + 10)
            guard let method = Method.fromRaw(rawMethod) else {
                throw ZipError.unsupportedCompression(rawMethod)
            }
            let nameLen = int(readU16LE(cd, cur + 28))
            let extraLen = int(readU16LE(cd, cur + 30))
            let commentLen = int(readU16LE(cd, cur + 32))
            let end = cur + 46 + nameLen + extraLen + commentLen
            if end > cd.count { throw ZipError.unexpectedEOF }
            var compSize = int64(readU32LE(cd, cur + 20))
            var uncompSize = int64(readU32LE(cd, cur + 24))
            var localOffset = int64(readU32LE(cd, cur + 42))
            // ZIP64 extra field (0x0001): the fields saturated at 0xFFFFFFFF,
            // in this order, as 8-byte values.
            var e = cur + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = readU16LE(cd, e)
                let len = int(readU16LE(cd, e + 2))
                if id == 0x0001 {
                    var f = e + 4
                    let fEnd = min(f + len, extraEnd)
                    if uncompSize == 0xFFFF_FFFF && f + 8 <= fEnd {
                        uncompSize = int64(readU64LE(cd, f))
                        f += 8
                    }
                    if compSize == 0xFFFF_FFFF && f + 8 <= fEnd {
                        compSize = int64(readU64LE(cd, f))
                        f += 8
                    }
                    if localOffset == 0xFFFF_FFFF && f + 8 <= fEnd {
                        localOffset = int64(readU64LE(cd, f))
                    }
                }
                e += 4 + len
            }
            let name = string(decoding: Array(cd[(cur + 46)..<(cur + 46 + nameLen)]), as: UTF8.self)
            let commentAt = cur + 46 + nameLen + extraLen
            let comment = commentLen > 0 ? string(decoding: Array(cd[commentAt..<(commentAt + commentLen)]), as: UTF8.self) : ""
            Files.append(FileHeader(
                name: name,
                method: method,
                uncompressedSize: uncompSize,
                compressedSize: compSize,
                crc32: readU32LE(cd, cur + 16),
                comment: comment,
                modifiedTime: readU16LE(cd, cur + 12),
                modifiedDate: readU16LE(cd, cur + 14),
                externalAttributes: readU32LE(cd, cur + 38),
                localHeaderOffset: localOffset
            ))
            cur = end
            n += 1
        }
    }
}

/// Reads `count` bytes of an archive's file from `start`, without moving
/// its position.
public struct Section: io.Reader {
    let archive: Archive
    var at: int64
    let end: int64

    init(_ archive: Archive, _ start: int64, _ count: int64) {
        self.archive = archive
        at = start
        end = start + count
    }

    public mutating func Read(into buffer: inout [uint8]) throws -> int {
        if at >= end || buffer.isEmpty { return 0 }
        if int64(buffer.count) > end - at {
            var part = [uint8](repeating: 0, count: int(end - at))
            let n = try archive.Handle.Read(into: &part, at: at)
            for i in 0..<n { buffer[i] = part[i] }
            at += int64(n)
            return n
        }
        let n = try archive.Handle.Read(into: &buffer, at: at)
        at += int64(n)
        return n
    }
}

/// One entry's uncompressed bytes, streamed from an Archive. Reading to
/// the end (Read returning 0) checks the size and the CRC-32.
public struct EntryReader: io.Reader {
    public let Header: FileHeader
    var stored: Section
    var inflater: flate.Inflater<Section>?
    var crc: uint32 = 0
    /// Uncompressed bytes read so far.
    public private(set) var Count: int64 = 0
    var checked = false

    init(_ header: FileHeader, _ section: Section) {
        Header = header
        stored = section
        inflater = header.Method == .deflate ? flate.Inflater(section) : nil
    }

    public mutating func Read(into buffer: inout [uint8]) throws -> int {
        if buffer.isEmpty { return 0 }
        var n = 0
        if Count < Header.UncompressedSize {
            if inflater != nil {
                n = try inflater!.Read(into: &buffer)
            } else {
                n = try stored.Read(into: &buffer)
            }
        }
        if n > 0 {
            crc = Update(crc, n == buffer.count ? buffer : Array(buffer[0..<n]))
            Count += int64(n)
            if Count > Header.UncompressedSize {
                throw ZipError.sizeMismatch(expected: Header.UncompressedSize, got: Count)
            }
            return n
        }
        if !checked {
            checked = true
            if Count != Header.UncompressedSize {
                throw ZipError.sizeMismatch(expected: Header.UncompressedSize, got: Count)
            }
            if crc != Header.CRC32 {
                throw ZipError.checksumMismatch(expected: Header.CRC32, got: crc)
            }
        }
        return 0
    }
}

func readU64LE(_ b: [uint8], _ offset: int) -> uint64 {
    uint64(readU32LE(b, offset)) | (uint64(readU32LE(b, offset + 4)) << 32)
}
