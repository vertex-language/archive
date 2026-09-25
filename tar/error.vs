package tar

/// Errors encountered while reading or writing TAR archives.
public enum TarError: Error, Equatable, CustomStringConvertible {
    /// The archive stream ended prematurely before a complete block or entry could be read.
    case unexpectedEOF
    /// The 512-byte header block is corrupted, malformed, or has an invalid magic identifier.
    case badHeader(string)
    /// The unsigned octal checksum in the header does not match the computed block checksum.
    case badChecksum(expected: int64, got: int64)
    /// An attempt was made to write more bytes than declared in the header's Size field.
    case writePastSize(expected: int64, got: int64)
    /// The entry was closed before the declared number of bytes were written.
    case writeIncomplete(expected: int64, got: int64)

    public var description: string {
        switch self {
        case .unexpectedEOF:
            return "unexpected end of tar archive"
        case .badHeader(let msg):
            return "corrupt tar header: \(msg)"
        case .badChecksum(let expected, let got):
            return "tar header checksum mismatch: expected \(expected), got \(got)"
        case .writePastSize(let expected, let got):
            return "wrote \(got) bytes for tar entry with declared size \(expected)"
        case .writeIncomplete(let expected, let got):
            return "closed tar entry having written \(got) bytes of declared size \(expected)"
        }
    }
}
