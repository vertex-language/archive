package tar

import "io"

/// Reader provides streaming access to the entries of a TAR archive.
public struct Reader<R: io.Reader>: io.Reader {
    public var Inner: R
    var currentHeader: Header?
    var remaining: int64 = 0
    var padRemaining: int = 0
    var atEOF: bool = false

    public init(_ inner: R) {
        self.Inner = inner
    }

    /// Advances to the next entry in the TAR stream.
    /// Returns the entry's Header, or nil if the end of the archive is reached.
    public mutating func Next() throws -> Header? {
        if atEOF {
            return nil
        }

        // Discard unread bytes and trailing block padding of the previous entry
        let skipTotal = remaining + int64(padRemaining)
        if skipTotal > 0 {
            var toSkip = skipTotal
            while toSkip > 0 {
                let want = toSkip > 4096 ? 4096 : int(toSkip)
                var buf = [uint8](repeating: 0, count: want)
                try io.ReadFull(&Inner, into: &buf)
                toSkip -= int64(want)
            }
        }
        remaining = 0
        padRemaining = 0

        // Read the 512-byte header block
        var block = [uint8](repeating: 0, count: 512)
        do {
            try io.ReadFull(&Inner, into: &block)
        } catch {
            atEOF = true
            return nil
        }

        // Check for 512-byte zero block
        var allZero = true
        var i = 0
        while i < 512 {
            if block[i] != 0 {
                allZero = false
                break
            }
            i += 1
        }

        if allZero {
            // Read second 512-byte zero block if present
            var block2 = [uint8](repeating: 0, count: 512)
            _ = try? io.ReadFull(&Inner, into: &block2)
            atEOF = true
            currentHeader = nil
            return nil
        }

        let parsed = try Header.parse(block)
        currentHeader = parsed
        remaining = parsed.Size
        let pad = int((512 - (parsed.Size % 512)) % 512)
        padRemaining = pad
        return parsed
    }

    /// Reads up to buffer.count bytes from the currently active entry.
    /// Returns 0 when the entry has been completely read.
    public mutating func Read(into buffer: inout [uint8]) throws -> int {
        if remaining <= 0 || buffer.isEmpty {
            return 0
        }
        let maxRead = remaining < int64(buffer.count) ? int(remaining) : buffer.count
        var tmp = [uint8](repeating: 0, count: maxRead)
        let n = try Inner.Read(into: &tmp)
        if n == 0 {
            throw TarError.unexpectedEOF
        }
        var i = 0
        while i < n {
            buffer[i] = tmp[i]
            i += 1
        }
        remaining -= int64(n)
        return n
    }

    /// Reads the entire payload of the currently active entry as bytes.
    public mutating func ReadAll() throws -> [uint8] {
        var out: [uint8] = []
        var buf = [uint8](repeating: 0, count: 4096)
        while true {
            let n = try Read(into: &buf)
            if n == 0 {
                break
            }
            var i = 0
            while i < n {
                out.append(buf[i])
                i += 1
            }
        }
        return out
    }
}
