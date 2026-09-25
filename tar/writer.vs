package tar

import "io"

/// Writer provides streaming construction of a TAR archive.
public struct Writer<W: io.Writer>: io.Writer, io.Closer {
    public var Inner: W
    var expectedSize: int64 = 0
    var writtenSize: int64 = 0
    var hasActiveHeader: bool = false
    var closed: bool = false

    public init(_ inner: W) {
        self.Inner = inner
    }

    /// Emits a 512-byte header block for a new entry.
    /// If a previous entry was active, pads it to a 512-byte boundary.
    public mutating func WriteHeader(_ header: Header) throws {
        if closed {
            throw TarError.badHeader("attempted write to closed tar archive")
        }
        if hasActiveHeader {
            if writtenSize < expectedSize {
                throw TarError.writeIncomplete(expected: expectedSize, got: writtenSize)
            }
            try padEntry(writtenSize)
        }

        let block = header.serialize()
        try Inner.Write(block)

        expectedSize = header.Size
        writtenSize = 0
        hasActiveHeader = true
    }

    /// Writes payload bytes for the currently active entry.
    public mutating func Write(_ bytes: borrowing [uint8]) throws {
        if closed {
            throw TarError.badHeader("attempted write to closed tar archive")
        }
        if !hasActiveHeader {
            throw TarError.badHeader("Write called before WriteHeader")
        }
        if writtenSize + int64(bytes.count) > expectedSize {
            throw TarError.writePastSize(expected: expectedSize, got: writtenSize + int64(bytes.count))
        }
        try Inner.Write(bytes)
        writtenSize += int64(bytes.count)
    }

    public mutating func Flush() throws {
        try Inner.Flush()
    }

    /// Finalizes the archive by padding the last entry and writing the dual 512-byte zero terminator blocks.
    public mutating func Close() throws {
        if closed {
            return
        }
        if hasActiveHeader {
            if writtenSize < expectedSize {
                throw TarError.writeIncomplete(expected: expectedSize, got: writtenSize)
            }
            try padEntry(writtenSize)
            hasActiveHeader = false
        }
        let zeros = [uint8](repeating: 0, count: 1024)
        try Inner.Write(zeros)
        try Inner.Flush()
        closed = true
    }

    mutating func padEntry(_ size: int64) throws {
        let pad = int((512 - (size % 512)) % 512)
        if pad > 0 {
            let padBytes = [uint8](repeating: 0, count: pad)
            try Inner.Write(padBytes)
        }
    }
}
