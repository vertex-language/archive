package zip

import "io"

/// Writer creates and formats ZIP archives streaming into an underlying io.Writer.
public struct Writer<W: io.Writer>: io.Closer {
    public var Inner: W
    var entries: [FileHeader] = []
    var currentOffset: int64 = 0
    var closed: bool = false

    public init(_ inner: W) {
        self.Inner = inner
    }

    /// Adds a file entry with the given uncompressed payload and compression method.
    public mutating func Add(
        name: string,
        data: [uint8],
        method: Method = .deflate,
        comment: string = ""
    ) throws {
        if closed {
            throw ZipError.badZip("attempted write to closed zip archive")
        }

        let crc = Checksum(data)
        let uncompressedSize = int64(data.count)

        var compressedBytes = data
        var actualMethod = method

        if method == .deflate {
            let deflated = Deflate(data)
            if deflated.count < data.count {
                compressedBytes = deflated
                actualMethod = .deflate
            } else {
                compressedBytes = data
                actualMethod = .store
            }
        }

        let compressedSize = int64(compressedBytes.count)
        let localHeaderOffset = currentOffset

        let nameBytes = [uint8](name.utf8)
        let nameLen = uint16(nameBytes.count)

        // Write Local File Header (30 bytes)
        var lfh = [uint8](repeating: 0, count: 30)
        // Signature: 0x04034b50
        lfh[0] = 0x50; lfh[1] = 0x4B; lfh[2] = 0x03; lfh[3] = 0x04
        // Version needed: 20
        lfh[4] = 20; lfh[5] = 0
        // General purpose bit flag: 0x0800 (UTF-8)
        lfh[6] = 0x00; lfh[7] = 0x08
        // Compression method
        let mBytes = writeU16LE(actualMethod.rawValue)
        lfh[8] = mBytes[0]; lfh[9] = mBytes[1]
        // Mod time / date: 0
        // CRC-32
        let crcBytes = writeU32LE(crc)
        for i in 0..<4 { lfh[14 + i] = crcBytes[i] }
        // Compressed size
        let cSizeBytes = writeU32LE(uint32(compressedSize))
        for i in 0..<4 { lfh[18 + i] = cSizeBytes[i] }
        // Uncompressed size
        let uSizeBytes = writeU32LE(uint32(uncompressedSize))
        for i in 0..<4 { lfh[22 + i] = uSizeBytes[i] }
        // Name length
        let nlBytes = writeU16LE(nameLen)
        lfh[26] = nlBytes[0]; lfh[27] = nlBytes[1]
        // Extra field length: 0
        lfh[28] = 0; lfh[29] = 0

        try Inner.Write(lfh)
        try Inner.Write(nameBytes)
        try Inner.Write(compressedBytes)

        currentOffset += int64(30 + nameBytes.count + compressedBytes.count)

        let isDir = name.hasSuffix("/")
        let extAttrs: uint32 = isDir ? 0x41ED0010 : 0x81A40000

        let header = FileHeader(
            name: name,
            method: actualMethod,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            crc32: crc,
            comment: comment,
            externalAttributes: extAttrs,
            localHeaderOffset: localHeaderOffset,
            isDir: isDir
        )
        entries.append(header)
    }

    /// Adds a directory entry to the ZIP archive.
    public mutating func AddDir(name: string) throws {
        var dirName = name
        if !dirName.hasSuffix("/") {
            dirName = dirName + "/"
        }
        try Add(name: dirName, data: [], method: .store)
    }

    /// Finalizes the ZIP archive by writing central directory file headers and the EOCD record.
    public mutating func Close() throws {
        if closed {
            return
        }

        let cdStartOffset = currentOffset

        for h in entries {
            let nameBytes = [uint8](h.Name.utf8)
            let commentBytes = [uint8](h.Comment.utf8)

            var cdh = [uint8](repeating: 0, count: 46)
            // Signature: 0x02014b50
            cdh[0] = 0x50; cdh[1] = 0x4B; cdh[2] = 0x01; cdh[3] = 0x02
            // Version made by: 0x0314 (Unix, ZIP 2.0)
            cdh[4] = 20; cdh[5] = 3
            // Version needed: 20
            cdh[6] = 20; cdh[7] = 0
            // Bit flag: 0x0800 (UTF-8)
            cdh[8] = 0x00; cdh[9] = 0x08
            // Method
            let mBytes = writeU16LE(h.Method.rawValue)
            cdh[10] = mBytes[0]; cdh[11] = mBytes[1]
            // Mod time / date: 0
            // CRC-32
            let crcBytes = writeU32LE(h.CRC32)
            for i in 0..<4 { cdh[16 + i] = crcBytes[i] }
            // Compressed size
            let csBytes = writeU32LE(uint32(h.CompressedSize))
            for i in 0..<4 { cdh[20 + i] = csBytes[i] }
            // Uncompressed size
            let usBytes = writeU32LE(uint32(h.UncompressedSize))
            for i in 0..<4 { cdh[24 + i] = usBytes[i] }
            // Name length
            let nlBytes = writeU16LE(uint16(nameBytes.count))
            cdh[28] = nlBytes[0]; cdh[29] = nlBytes[1]
            // Extra len: 0
            cdh[30] = 0; cdh[31] = 0
            // Comment length
            let clBytes = writeU16LE(uint16(commentBytes.count))
            cdh[32] = clBytes[0]; cdh[33] = clBytes[1]
            // Disk start: 0
            cdh[34] = 0; cdh[35] = 0
            // Internal attrs: 0
            cdh[36] = 0; cdh[37] = 0
            // External attrs
            let eaBytes = writeU32LE(h.ExternalAttributes)
            for i in 0..<4 { cdh[38 + i] = eaBytes[i] }
            // Local header offset
            let lhoBytes = writeU32LE(uint32(h.LocalHeaderOffset))
            for i in 0..<4 { cdh[42 + i] = lhoBytes[i] }

            try Inner.Write(cdh)
            try Inner.Write(nameBytes)
            if !commentBytes.isEmpty {
                try Inner.Write(commentBytes)
            }
            currentOffset += int64(46 + nameBytes.count + commentBytes.count)
        }

        let cdSize = currentOffset - cdStartOffset

        // Write EOCD record (22 bytes)
        var eocd = [uint8](repeating: 0, count: 22)
        // Signature: 0x06054b50
        eocd[0] = 0x50; eocd[1] = 0x4B; eocd[2] = 0x05; eocd[3] = 0x06
        // Disk numbers: 0
        // Entries on this disk
        let cntBytes = writeU16LE(uint16(entries.count))
        eocd[8] = cntBytes[0]; eocd[9] = cntBytes[1]
        // Total entries
        eocd[10] = cntBytes[0]; eocd[11] = cntBytes[1]
        // Size of CD
        let cdsBytes = writeU32LE(uint32(cdSize))
        for i in 0..<4 { eocd[12 + i] = cdsBytes[i] }
        // Offset of CD
        let cdoBytes = writeU32LE(uint32(cdStartOffset))
        for i in 0..<4 { eocd[16 + i] = cdoBytes[i] }
        // Comment len: 0
        eocd[20] = 0; eocd[21] = 0

        try Inner.Write(eocd)
        try Inner.Flush()
        closed = true
    }
}
