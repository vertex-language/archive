package tar

import "io"

/// Reader provides streaming access to the entries of a TAR archive.
public struct Reader<R: io.Reader>: io.Reader {
    public var Inner: R
    var currentHeader: Header?
    var remaining: int64 = 0
    var padRemaining: int = 0
    var atEOF: bool = false
    /// PAX / GNU records for the next entry, and PAX global records.
    var pending: [string: string] = [:]
    var global: [string: string] = [:]

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

        var parsed = try Header.parse(block)
        remaining = parsed.Size
        padRemaining = int((512 - (parsed.Size % 512)) % 512)

        // Extension headers carry what the USTAR fields can't for the
        // entry after them: read them, then that entry.
        switch parsed.Typeflag {
        case .paxHeader, .paxGlobal, .gnuLongName, .gnuLongLink:
            let payload = try ReadAll()
            switch parsed.Typeflag {
            case .paxHeader:
                for (k, v) in parsePax(payload) { pending[k] = v }
            case .paxGlobal:
                for (k, v) in parsePax(payload) { global[k] = v }
            case .gnuLongName:
                pending["path"] = cString(payload)
            default:
                pending["linkpath"] = cString(payload)
            }
            return try Next()
        default:
            break
        }
        for (k, v) in global where pending[k] == nil { pending[k] = v }
        apply(pending, to: &parsed)
        pending = [:]
        currentHeader = parsed
        remaining = parsed.Size
        padRemaining = int((512 - (parsed.Size % 512)) % 512)
        return parsed
    }

    /// PAX records override the header's fields they name.
    func apply(_ records: [string: string], to h: inout Header) {
        if let v = records["path"] { h.Name = v; h.Prefix = "" }
        if let v = records["linkpath"] { h.Linkname = v }
        if let v = records["size"], let n = int64(v) { h.Size = n }
        if let v = records["uid"], let n = int(v) { h.Uid = n }
        if let v = records["gid"], let n = int(v) { h.Gid = n }
        if let v = records["uname"] { h.Uname = v }
        if let v = records["gname"] { h.Gname = v }
        if let v = records["mtime"] {
            // Seconds, perhaps with a fraction.
            let whole = v.split(separator: ".").first.map { string($0) } ?? v
            if let n = int64(whole) { h.ModTime = n }
        }
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

/// PAX extended header records: "<length> <key>=<value>\n", where the
/// length counts the whole record.
func parsePax(_ data: [uint8]) -> [string: string] {
    var out: [string: string] = [:]
    var i = 0
    while i < data.count {
        var j = i
        var length = 0
        while j < data.count && data[j] >= 0x30 && data[j] <= 0x39 {
            length = length * 10 + int(data[j] - 0x30)
            j += 1
        }
        if length <= 0 || j >= data.count || data[j] != 0x20 || i + length > data.count {
            break
        }
        let record = Array(data[(j + 1)..<(i + length - 1)])   // drop the space and the newline
        if let eq = record.firstIndex(of: 0x3d) {
            let key = string(decoding: Array(record[0..<eq]), as: UTF8.self)
            let value = string(decoding: Array(record[(eq + 1)...]), as: UTF8.self)
            out[key] = value
        }
        i += length
    }
    return out
}

/// A NUL-terminated string's bytes as text (a GNU long name is one).
func cString(_ data: [uint8]) -> string {
    let end = data.firstIndex(of: 0) ?? data.count
    return string(decoding: Array(data[0..<end]), as: UTF8.self)
}
