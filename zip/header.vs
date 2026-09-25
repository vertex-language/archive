package zip

/// The compression method applied to an entry in a ZIP archive.
public enum Method: Equatable, CustomStringConvertible {
    /// Uncompressed raw bytes.
    case store
    /// RFC 1951 DEFLATE compressed bytes.
    case deflate

    public var rawValue: uint16 {
        switch self {
        case .store: return 0
        case .deflate: return 8
        }
    }

    public static func fromRaw(_ val: uint16) -> Method? {
        switch val {
        case 0: return .store
        case 8: return .deflate
        default: return nil
        }
    }

    public var description: string {
        switch self {
        case .store: return "Store"
        case .deflate: return "Deflate"
        }
    }
}

/// Metadata describing a file entry within a ZIP archive.
public struct FileHeader: Equatable {
    public var Name: string
    public var Comment: string
    public var Method: Method
    public var CRC32: uint32
    public var CompressedSize: int64
    public var UncompressedSize: int64
    public var ModifiedTime: uint16
    public var ModifiedDate: uint16
    public var ExternalAttributes: uint32
    public var LocalHeaderOffset: int64
    public var IsDir: bool

    public init(
        name: string,
        method: Method = .deflate,
        uncompressedSize: int64 = 0,
        compressedSize: int64 = 0,
        crc32: uint32 = 0,
        comment: string = "",
        modifiedTime: uint16 = 0,
        modifiedDate: uint16 = 0,
        externalAttributes: uint32 = 0,
        localHeaderOffset: int64 = 0,
        isDir: bool = false
    ) {
        self.Name = name
        self.Method = method
        self.UncompressedSize = uncompressedSize
        self.CompressedSize = compressedSize
        self.CRC32 = crc32
        self.Comment = comment
        self.ModifiedTime = modifiedTime
        self.ModifiedDate = modifiedDate
        self.ExternalAttributes = externalAttributes
        self.LocalHeaderOffset = localHeaderOffset
        self.IsDir = isDir || name.hasSuffix("/")
    }
}

// Little-endian binary serialization helpers:

func readU16LE(_ b: [uint8], _ offset: int) -> uint16 {
    return uint16(b[offset]) | (uint16(b[offset + 1]) << 8)
}

func readU32LE(_ b: [uint8], _ offset: int) -> uint32 {
    let b0 = uint32(b[offset])
    let b1 = uint32(b[offset + 1]) << 8
    let b2 = uint32(b[offset + 2]) << 16
    let b3 = uint32(b[offset + 3]) << 24
    return b0 | b1 | b2 | b3
}

func writeU16LE(_ v: uint16) -> [uint8] {
    return [
        uint8(v & 0xFF),
        uint8((v >> 8) & 0xFF)
    ]
}

func writeU32LE(_ v: uint32) -> [uint8] {
    return [
        uint8(v & 0xFF),
        uint8((v >> 8) & 0xFF),
        uint8((v >> 16) & 0xFF),
        uint8((v >> 24) & 0xFF)
    ]
}
