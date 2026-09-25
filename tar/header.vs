package tar

/// The type of file entry stored in a TAR archive.
public enum FileType: Equatable, CustomStringConvertible {
    case regular
    case link
    case symlink
    case characterDevice
    case blockDevice
    case directory
    case fifo
    case contiguous

    public var description: string {
        switch self {
        case .regular:
            return "regular"
        case .link:
            return "link"
        case .symlink:
            return "symlink"
        case .characterDevice:
            return "characterDevice"
        case .blockDevice:
            return "blockDevice"
        case .directory:
            return "directory"
        case .fifo:
            return "fifo"
        case .contiguous:
            return "contiguous"
        }
    }

    public var typeflagByte: uint8 {
        switch self {
        case .regular:
            return 0x30 // '0'
        case .link:
            return 0x31 // '1'
        case .symlink:
            return 0x32 // '2'
        case .characterDevice:
            return 0x33 // '3'
        case .blockDevice:
            return 0x34 // '4'
        case .directory:
            return 0x35 // '5'
        case .fifo:
            return 0x36 // '6'
        case .contiguous:
            return 0x37 // '7'
        }
    }

    public static func fromByte(_ b: uint8) -> FileType {
        switch b {
        case 0, 0x30:
            return .regular
        case 0x31:
            return .link
        case 0x32:
            return .symlink
        case 0x33:
            return .characterDevice
        case 0x34:
            return .blockDevice
        case 0x35:
            return .directory
        case 0x36:
            return .fifo
        case 0x37:
            return .contiguous
        default:
            return .regular
        }
    }
}

/// A 512-byte POSIX.1-1988 USTAR TAR file header.
public struct Header: Equatable {
    public var Name: string
    public var Mode: int64
    public var Uid: int
    public var Gid: int
    public var Size: int64
    public var ModTime: int64
    public var Typeflag: FileType
    public var Linkname: string
    public var Uname: string
    public var Gname: string
    public var Devmajor: int64
    public var Devminor: int64
    public var Prefix: string

    public init(
        name: string,
        size: int64 = 0,
        mode: int64 = 0o644,
        typeflag: FileType = .regular,
        modTime: int64 = 0,
        uid: int = 0,
        gid: int = 0,
        linkname: string = "",
        uname: string = "",
        gname: string = "",
        devmajor: int64 = 0,
        devminor: int64 = 0,
        prefix: string = ""
    ) {
        self.Name = name
        self.Size = size
        self.Mode = mode
        self.Typeflag = typeflag
        self.ModTime = modTime
        self.Uid = uid
        self.Gid = gid
        self.Linkname = linkname
        self.Uname = uname
        self.Gname = gname
        self.Devmajor = devmajor
        self.Devminor = devminor
        self.Prefix = prefix
    }

    /// Serializes this header into a standard 512-byte USTAR block.
    public func serialize() -> [uint8] {
        var block = [uint8](repeating: 0, count: 512)

        var finalName = Name
        var finalPrefix = Prefix

        // If Name > 100 bytes and Prefix is empty, split into Prefix and Name if possible
        let nameBytes = [uint8](Name.utf8)
        if nameBytes.count > 100 && finalPrefix.isEmpty {
            var splitIdx = -1
            var idx = nameBytes.count > 155 ? 155 : nameBytes.count - 1
            while idx >= 0 {
                if nameBytes[idx] == 0x2F { // '/'
                    if idx <= 155 && (nameBytes.count - idx - 1) <= 100 {
                        splitIdx = idx
                        break
                    }
                }
                idx -= 1
            }
            if splitIdx > 0 {
                var pBytes = [uint8](repeating: 0, count: splitIdx)
                for i in 0..<splitIdx { pBytes[i] = nameBytes[i] }
                finalPrefix = string(decoding: pBytes, as: UTF8.self)

                let restLen = nameBytes.count - splitIdx - 1
                var nBytes = [uint8](repeating: 0, count: restLen)
                for i in 0..<restLen { nBytes[i] = nameBytes[splitIdx + 1 + i] }
                finalName = string(decoding: nBytes, as: UTF8.self)
            }
        }

        // 0..100: name
        copyString(&block, at: 0, maxLen: 100, str: finalName)
        // 100..108: mode
        copyOctal(&block, at: 100, len: 8, val: Mode)
        // 108..116: uid
        copyOctal(&block, at: 108, len: 8, val: int64(Uid))
        // 116..124: gid
        copyOctal(&block, at: 116, len: 8, val: int64(Gid))
        // 124..136: size
        copyOctal(&block, at: 124, len: 12, val: Size)
        // 136..148: mtime
        copyOctal(&block, at: 136, len: 12, val: ModTime)

        // 148..156: chksum (filled with spaces during checksumming)
        for i in 0..<8 {
            block[148 + i] = 0x20
        }

        // 156: typeflag
        block[156] = Typeflag.typeflagByte

        // 157..257: linkname
        copyString(&block, at: 157, maxLen: 100, str: Linkname)

        // 257..263: magic ("ustar\0")
        block[257] = 0x75 // 'u'
        block[258] = 0x73 // 's'
        block[259] = 0x74 // 't'
        block[260] = 0x61 // 'a'
        block[261] = 0x72 // 'r'
        block[262] = 0x00

        // 263..265: version ("00")
        block[263] = 0x30
        block[264] = 0x30

        // 265..297: uname
        copyString(&block, at: 265, maxLen: 32, str: Uname)
        // 297..329: gname
        copyString(&block, at: 297, maxLen: 32, str: Gname)
        // 329..337: devmajor
        if Devmajor > 0 {
            copyOctal(&block, at: 329, len: 8, val: Devmajor)
        }
        // 337..345: devminor
        if Devminor > 0 {
            copyOctal(&block, at: 337, len: 8, val: Devminor)
        }
        // 345..500: prefix
        copyString(&block, at: 345, maxLen: 155, str: finalPrefix)

        // Calculate unsigned checksum
        var sum: int64 = 0
        for b in block {
            sum += int64(b)
        }

        // Format checksum: 6 octal digits + null + space
        let chk = formatOctal(sum, 7)
        for i in 0..<6 {
            block[148 + i] = chk[i]
        }
        block[148 + 6] = 0x00
        block[148 + 7] = 0x20

        return block
    }

    /// Parses a 512-byte block into a TAR Header.
    public static func parse(_ block: [uint8]) throws -> Header {
        if block.count < 512 {
            throw TarError.badHeader("block length is \(block.count), expected 512")
        }

        // Compute unsigned checksum with checksum field treated as 8 spaces (0x20)
        let storedChecksum = parseOctal(block, start: 148, len: 8)
        var computedChecksum: int64 = 0
        var i = 0
        while i < 512 {
            if i >= 148 && i < 156 {
                computedChecksum += 0x20
            } else {
                computedChecksum += int64(block[i])
            }
            i += 1
        }

        if storedChecksum != computedChecksum {
            throw TarError.badChecksum(expected: storedChecksum, got: computedChecksum)
        }

        var name = readString(block, start: 0, maxLen: 100)
        let mode = parseOctal(block, start: 100, len: 8)
        let uid = int(parseOctal(block, start: 108, len: 8))
        let gid = int(parseOctal(block, start: 116, len: 8))
        let size = parseOctal(block, start: 124, len: 12)
        let mtime = parseOctal(block, start: 136, len: 12)
        let typeflag = FileType.fromByte(block[156])
        let linkname = readString(block, start: 157, maxLen: 100)
        let uname = readString(block, start: 265, maxLen: 32)
        let gname = readString(block, start: 297, maxLen: 32)
        let devmajor = parseOctal(block, start: 329, len: 8)
        let devminor = parseOctal(block, start: 337, len: 8)
        let prefix = readString(block, start: 345, maxLen: 155)

        if !prefix.isEmpty {
            name = prefix + "/" + name
        }

        return Header(
            name: name,
            size: size,
            mode: mode,
            typeflag: typeflag,
            modTime: mtime,
            uid: uid,
            gid: gid,
            linkname: linkname,
            uname: uname,
            gname: gname,
            devmajor: devmajor,
            devminor: devminor,
            prefix: prefix
        )
    }
}

// Helpers for octal numbers and strings in 512-byte blocks:

func parseOctal(_ bytes: [uint8], start: int, len: int) -> int64 {
    var val: int64 = 0
    var i = start
    let end = start + len
    while i < end && (bytes[i] == 0x20 || bytes[i] == 0) {
        i += 1
    }
    while i < end {
        let b = bytes[i]
        if b < 0x30 || b > 0x37 {
            break
        }
        val = (val << 3) | int64(b - 0x30)
        i += 1
    }
    return val
}

func formatOctal(_ value: int64, _ len: int) -> [uint8] {
    var out = [uint8](repeating: 0x30, count: len)
    out[len - 1] = 0
    var v = value
    var idx = len - 2
    while idx >= 0 {
        let digit = uint8(v & 7)
        out[idx] = 0x30 + digit
        v = v >> 3
        idx -= 1
        if v == 0 {
            break
        }
    }
    return out
}

func readString(_ bytes: [uint8], start: int, maxLen: int) -> string {
    var strBytes: [uint8] = []
    var i = start
    let end = start + maxLen
    while i < end && i < bytes.count && bytes[i] != 0 {
        strBytes.append(bytes[i])
        i += 1
    }
    return string(decoding: strBytes, as: UTF8.self)
}

func copyString(_ dst: inout [uint8], at: int, maxLen: int, str: string) {
    let utf8 = [uint8](str.utf8)
    var i = 0
    while i < utf8.count && i < maxLen {
        dst[at + i] = utf8[i]
        i += 1
    }
}

func copyOctal(_ dst: inout [uint8], at: int, len: int, val: int64) {
    let oct = formatOctal(val, len)
    for i in 0..<len {
        dst[at + i] = oct[i]
    }
}
