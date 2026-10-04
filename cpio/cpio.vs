// Package cpio reads and writes cpio archives in the "newc" format (SVR4,
// magic 070701): what a Linux initramfs is. Each entry is a 110-byte
// ASCII header, its NUL-terminated name and then its data, both padded
// to four bytes; the archive ends with an entry named TRAILER!!!.
//
// Unlike tar, newc carries the whole of what a Linux file is -- owner,
// mode, device numbers, inode for hard links -- in fixed fields, so an
// image's files go into one exactly as the kernel will unpack them.
package cpio

import "io"

/// The file type bits of a Mode (`S_IFMT` and its values).
public enum ModeType {
    public static let mask: uint32 = 0o170000
    public static let socket: uint32 = 0o140000
    public static let symlink: uint32 = 0o120000
    public static let regular: uint32 = 0o100000
    public static let blockDevice: uint32 = 0o060000
    public static let directory: uint32 = 0o040000
    public static let charDevice: uint32 = 0o020000
    public static let fifo: uint32 = 0o010000
}

public enum CpioError: Error, Equatable, CustomStringConvertible {
    case unexpectedEOF
    case badHeader(string)
    case writePastSize(expected: int64, got: int64)
    case writeIncomplete(expected: int64, got: int64)

    public var description: string {
        switch self {
        case .unexpectedEOF:
            return "unexpected end of cpio archive"
        case .badHeader(let msg):
            return "corrupt cpio header: \(msg)"
        case .writePastSize(let expected, let got):
            return "wrote \(got) bytes for a cpio entry of size \(expected)"
        case .writeIncomplete(let expected, let got):
            return "cpio entry ended at \(got) of its \(expected) bytes"
        }
    }
}

/// The name of the entry that ends an archive.
public let Trailer = "TRAILER!!!"

/// One entry's metadata.
public struct Header: Equatable {
    /// The path inside the archive, without a leading "/": "bin/sh".
    public var Name: string
    /// Type bits and permission bits together: 0o100755 is an
    /// executable regular file.
    public var Mode: uint32
    public var Uid: uint32
    public var Gid: uint32
    public var Nlink: uint32
    public var ModTime: int64
    /// The data's length: a file's contents, a symlink's target.
    public var Size: int64
    public var Inode: uint32
    public var DevMajor: uint32
    public var DevMinor: uint32
    /// What a device node stands for.
    public var RdevMajor: uint32
    public var RdevMinor: uint32

    public init(name: string, mode: uint32, uid: uint32 = 0, gid: uint32 = 0, nlink: uint32 = 1,
                modTime: int64 = 0, size: int64 = 0, inode: uint32 = 0,
                rdevMajor: uint32 = 0, rdevMinor: uint32 = 0) {
        Name = name
        Mode = mode
        Uid = uid
        Gid = gid
        Nlink = nlink
        ModTime = modTime
        Size = size
        Inode = inode
        DevMajor = 0
        DevMinor = 0
        RdevMajor = rdevMajor
        RdevMinor = rdevMinor
    }

    /// The type bits alone: one of ModeType's.
    public var Kind: uint32 { Mode & ModeType.mask }

    /// The header and name as written, padded to four bytes.
    public func Encode() -> [uint8] {
        var out = [uint8]("070701".utf8)
        let name = [uint8](Name.utf8)
        for v in [Inode, Mode, Uid, Gid, Nlink, uint32(truncatingIfNeeded: ModTime),
                  uint32(truncatingIfNeeded: Size), DevMajor, DevMinor, RdevMajor, RdevMinor,
                  uint32(name.count + 1), 0] {
            out.append(contentsOf: hex8(v))
        }
        out.append(contentsOf: name)
        out.append(0)
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    /// Parses the 110 fixed bytes of a header; the name follows them.
    /// Returns the header (with an empty Name) and the name's size.
    public static func Parse(_ b: [uint8]) throws -> (Header, int) {
        if b.count < 110 { throw CpioError.unexpectedEOF }
        let magic = string(decoding: Array(b[0..<6]), as: UTF8.self)
        if magic != "070701" && magic != "070702" {
            throw CpioError.badHeader("magic \(magic) is not newc (070701)")
        }
        var f = [uint32](repeating: 0, count: 13)
        for i in 0..<13 {
            guard let v = parseHex8(b, at: 6 + 8 * i) else {
                throw CpioError.badHeader("field \(i) is not hex")
            }
            f[i] = v
        }
        var h = Header(name: "", mode: f[1], uid: f[2], gid: f[3], nlink: f[4],
                       modTime: int64(f[5]), size: int64(f[6]), inode: f[0],
                       rdevMajor: f[9], rdevMinor: f[10])
        h.DevMajor = f[7]
        h.DevMinor = f[8]
        return (h, int(f[11]))
    }
}

func hex8(_ v: uint32) -> [uint8] {
    let digits: [uint8] = [uint8]("0123456789abcdef".utf8)
    var out = [uint8](repeating: 0x30, count: 8)
    var x = v
    var i = 7
    while i >= 0 {
        out[i] = digits[int(x & 0xF)]
        x = x >> 4
        i -= 1
    }
    return out
}

func parseHex8(_ b: [uint8], at: int) -> uint32? {
    var v: uint32 = 0
    for i in 0..<8 {
        let c = b[at + i]
        var d: uint32 = 0
        if c >= 0x30 && c <= 0x39 {
            d = uint32(c - 0x30)
        } else if c >= 0x61 && c <= 0x66 {
            d = uint32(c - 0x61 + 10)
        } else if c >= 0x41 && c <= 0x46 {
            d = uint32(c - 0x41 + 10)
        } else {
            return nil
        }
        v = (v << 4) | d
    }
    return v
}

/// Zero bytes that bring `n` up to a multiple of four.
public func Padding(_ n: int64) -> int {
    int((4 - n % 4) % 4)
}

/// Writer writes a newc archive: WriteHeader for each entry, then Write
/// its Size bytes of data; Close writes the trailer.
public struct Writer<W: io.Writer>: io.Writer, io.Closer {
    public var Inner: W
    var expected: int64 = 0
    var written: int64 = 0
    var active: bool = false
    var closed: bool = false
    var nextInode: uint32 = 1

    public init(_ inner: W) {
        Inner = inner
    }

    mutating func finishEntry() throws {
        if !active { return }
        if written != expected {
            throw CpioError.writeIncomplete(expected: expected, got: written)
        }
        let pad = Padding(written)
        if pad > 0 {
            try Inner.Write([uint8](repeating: 0, count: pad))
        }
        active = false
    }

    /// Starts an entry. An Inode of 0 is given the next unused number.
    public mutating func WriteHeader(_ header: Header) throws {
        try finishEntry()
        var h = header
        if h.Inode == 0 {
            h.Inode = nextInode
            nextInode += 1
        } else if h.Inode >= nextInode {
            nextInode = h.Inode + 1
        }
        try Inner.Write(h.Encode())
        expected = h.Size
        written = 0
        active = true
    }

    public mutating func Write(_ bytes: borrowing [uint8]) throws {
        if !active || written + int64(bytes.count) > expected {
            throw CpioError.writePastSize(expected: expected, got: written + int64(bytes.count))
        }
        try Inner.Write(bytes)
        written += int64(bytes.count)
    }

    public mutating func Flush() throws {
        try Inner.Flush()
    }

    /// Ends the last entry and writes the trailer. The archive is then
    /// complete; Inner is not closed.
    public mutating func Close() throws {
        if closed { return }
        try finishEntry()
        try Inner.Write(Header(name: "TRAILER!!!", mode: 0, nlink: 1).Encode())
        try Inner.Flush()
        closed = true
    }
}

/// Reader reads a newc archive: Next for each entry's header, then Read
/// its data. Next returns nil at the trailer.
public struct Reader<R: io.Reader>: io.Reader {
    public var Inner: R
    var remaining: int64 = 0
    var pad: int = 0
    var done: bool = false

    public init(_ inner: R) {
        Inner = inner
    }

    public mutating func Next() throws -> Header? {
        if done { return nil }
        // What is left of the entry before, and its padding.
        var skip = remaining + int64(pad)
        while skip > 0 {
            var buf = [uint8](repeating: 0, count: skip > 4096 ? 4096 : int(skip))
            try io.ReadFull(&Inner, into: &buf)
            skip -= int64(buf.count)
        }
        var fixed = [uint8](repeating: 0, count: 110)
        do {
            try io.ReadFull(&Inner, into: &fixed)
        } catch {
            throw CpioError.unexpectedEOF
        }
        var (h, nameSize) = try Header.Parse(fixed)
        if nameSize < 1 { throw CpioError.badHeader("empty name") }
        var name = [uint8](repeating: 0, count: nameSize + Padding(int64(110 + nameSize)))
        try io.ReadFull(&Inner, into: &name)
        h.Name = string(decoding: Array(name[0..<(nameSize - 1)]), as: UTF8.self)
        if h.Name == "TRAILER!!!" {
            done = true
            return nil
        }
        remaining = h.Size
        pad = Padding(h.Size)
        return h
    }

    public mutating func Read(into buffer: inout [uint8]) throws -> int {
        if remaining <= 0 || buffer.isEmpty { return 0 }
        if int64(buffer.count) > remaining {
            var part = [uint8](repeating: 0, count: int(remaining))
            let n = try Inner.Read(into: &part)
            if n == 0 { throw CpioError.unexpectedEOF }
            for i in 0..<n { buffer[i] = part[i] }
            remaining -= int64(n)
            return n
        }
        let n = try Inner.Read(into: &buffer)
        if n == 0 { throw CpioError.unexpectedEOF }
        remaining -= int64(n)
        return n
    }

    /// The rest of the current entry's data.
    public mutating func ReadAll() throws -> [uint8] {
        var out = [uint8](repeating: 0, count: int(remaining))
        if !out.isEmpty {
            try io.ReadFull(&Inner, into: &out)
        }
        remaining = 0
        return out
    }
}
