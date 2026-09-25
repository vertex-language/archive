package zip

/// Errors encountered while parsing, extracting, or creating ZIP archives.
public enum ZipError: Error, Equatable, CustomStringConvertible {
    /// The archive stream ended before expected headers, records, or payloads were complete.
    case unexpectedEOF
    /// The archive structure is corrupted or fails specification invariants.
    case badZip(string)
    /// The computed CRC-32 checksum did not match the entry's header value.
    case checksumMismatch(expected: uint32, got: uint32)
    /// The decompressed byte count does not match the header's declared uncompressed size.
    case sizeMismatch(expected: int64, got: int64)
    /// An entry uses a compression method other than Store (0) or Deflate (8).
    case unsupportedCompression(uint16)
    /// A file was requested that is not present in the archive's central directory.
    case fileNotFound(string)

    public var description: string {
        switch self {
        case .unexpectedEOF:
            return "unexpected end of zip archive"
        case .badZip(let msg):
            return "corrupt zip archive: \(msg)"
        case .checksumMismatch(let exp, let got):
            return "zip crc32 mismatch: expected \(exp), got \(got)"
        case .sizeMismatch(let exp, let got):
            return "zip uncompressed size mismatch: expected \(exp), got \(got)"
        case .unsupportedCompression(let method):
            return "unsupported zip compression method: \(method)"
        case .fileNotFound(let name):
            return "file not found in zip archive: \(name)"
        }
    }
}
