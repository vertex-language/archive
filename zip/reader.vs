package zip

import "io"

/// An individual file entry inside a ZIP archive.
public struct File {
    public var Header: FileHeader
    var archiveData: [uint8]

    public var Name: string { return Header.Name }
    public var Comment: string { return Header.Comment }
    public var Method: Method { return Header.Method }
    public var CRC32: uint32 { return Header.CRC32 }
    public var CompressedSize: int64 { return Header.CompressedSize }
    public var UncompressedSize: int64 { return Header.UncompressedSize }
    public var IsDir: bool { return Header.IsDir }

    /// Reads and decompresses the payload, validating the CRC-32 checksum and size.
    public func Read() throws -> [uint8] {
        let offset = int(Header.LocalHeaderOffset)
        if offset + 30 > archiveData.count {
            throw ZipError.unexpectedEOF
        }
        // Check local file header signature: 0x04034b50
        if archiveData[offset] != 0x50 || archiveData[offset + 1] != 0x4B ||
           archiveData[offset + 2] != 0x03 || archiveData[offset + 3] != 0x04 {
            throw ZipError.badZip("invalid local file header signature at offset \(offset)")
        }

        let localNameLen = int(readU16LE(archiveData, offset + 26))
        let localExtraLen = int(readU16LE(archiveData, offset + 28))
        let dataOffset = offset + 30 + localNameLen + localExtraLen

        let compSize = int(Header.CompressedSize)
        if dataOffset + compSize > archiveData.count {
            throw ZipError.unexpectedEOF
        }

        var compressedBytes = [uint8](repeating: 0, count: compSize)
        var i = 0
        while i < compSize {
            compressedBytes[i] = archiveData[dataOffset + i]
            i += 1
        }

        var result: [uint8] = []
        switch Header.Method {
        case .store:
            result = compressedBytes
        case .deflate:
            result = try Inflate(compressedBytes, sizeHint: int(Header.UncompressedSize))
        }

        if int64(result.count) != Header.UncompressedSize {
            throw ZipError.sizeMismatch(expected: Header.UncompressedSize, got: int64(result.count))
        }

        let actualCRC = Checksum(result)
        if actualCRC != Header.CRC32 {
            throw ZipError.checksumMismatch(expected: Header.CRC32, got: actualCRC)
        }

        return result
    }

    /// Returns an io.Cursor over the decompressed bytes of this entry.
    public func Open() throws -> io.Cursor {
        let data = try Read()
        return io.Cursor(data)
    }
}

/// Reader provides random-access inspection and extraction of ZIP archives.
public struct Reader {
    public var Files: [File]
    public var Comment: string
    var data: [uint8]

    public init(_ bytes: [uint8]) throws {
        self.data = bytes
        self.Files = []
        self.Comment = ""

        if bytes.count < 22 {
            throw ZipError.badZip("archive smaller than minimum zip size (22 bytes)")
        }

        // Locate End of Central Directory Record (EOCD)
        var eocdOffset = -1
        let maxScan = bytes.count > 65557 ? 65557 : bytes.count
        var i = bytes.count - 22
        let stop = bytes.count - maxScan
        while i >= stop {
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        if eocdOffset < 0 {
            throw ZipError.badZip("end of central directory record not found")
        }

        let entryCount = int(readU16LE(bytes, eocdOffset + 10))
        let cdSize = int(readU32LE(bytes, eocdOffset + 12))
        let cdOffset = int(readU32LE(bytes, eocdOffset + 16))
        let commentLen = int(readU16LE(bytes, eocdOffset + 20))

        if eocdOffset + 22 + commentLen <= bytes.count && commentLen > 0 {
            var cBytes = [uint8](repeating: 0, count: commentLen)
            var ci = 0
            while ci < commentLen {
                cBytes[ci] = bytes[eocdOffset + 22 + ci]
                ci += 1
            }
            self.Comment = string(decoding: cBytes, as: UTF8.self)
        }

        if cdOffset + cdSize > bytes.count {
            throw ZipError.badZip("central directory extends beyond file")
        }

        // Parse central directory headers
        var cur = cdOffset
        var parsedCount = 0
        while parsedCount < entryCount && cur < cdOffset + cdSize {
            if cur + 46 > bytes.count {
                throw ZipError.unexpectedEOF
            }
            // Central directory signature: 0x02014b50
            if bytes[cur] != 0x50 || bytes[cur + 1] != 0x4B ||
               bytes[cur + 2] != 0x01 || bytes[cur + 3] != 0x02 {
                throw ZipError.badZip("invalid central directory signature at offset \(cur)")
            }

            let rawMethod = readU16LE(bytes, cur + 10)
            guard let method = Method.fromRaw(rawMethod) else {
                throw ZipError.unsupportedCompression(rawMethod)
            }
            let modTime = readU16LE(bytes, cur + 12)
            let modDate = readU16LE(bytes, cur + 14)
            let crc32 = readU32LE(bytes, cur + 16)
            let compSize = int64(readU32LE(bytes, cur + 20))
            let uncompSize = int64(readU32LE(bytes, cur + 24))
            let nameLen = int(readU16LE(bytes, cur + 28))
            let extraLen = int(readU16LE(bytes, cur + 30))
            let fileCommentLen = int(readU16LE(bytes, cur + 32))
            let extAttrs = readU32LE(bytes, cur + 38)
            let localHeaderOffset = int64(readU32LE(bytes, cur + 42))

            let nameStart = cur + 46
            if nameStart + nameLen > bytes.count {
                throw ZipError.unexpectedEOF
            }
            var nameBytes = [uint8](repeating: 0, count: nameLen)
            var ni = 0
            while ni < nameLen {
                nameBytes[ni] = bytes[nameStart + ni]
                ni += 1
            }
            let name = string(decoding: nameBytes, as: UTF8.self)

            var fileComment = ""
            let commentStart = nameStart + nameLen + extraLen
            if commentStart + fileCommentLen <= bytes.count && fileCommentLen > 0 {
                var fcBytes = [uint8](repeating: 0, count: fileCommentLen)
                var fci = 0
                while fci < fileCommentLen {
                    fcBytes[fci] = bytes[commentStart + fci]
                    fci += 1
                }
                fileComment = string(decoding: fcBytes, as: UTF8.self)
            }

            let header = FileHeader(
                name: name,
                method: method,
                uncompressedSize: uncompSize,
                compressedSize: compSize,
                crc32: crc32,
                comment: fileComment,
                modifiedTime: modTime,
                modifiedDate: modDate,
                externalAttributes: extAttrs,
                localHeaderOffset: localHeaderOffset
            )

            self.Files.append(File(Header: header, archiveData: bytes))
            cur += 46 + nameLen + extraLen + fileCommentLen
            parsedCount += 1
        }
    }

    /// Finds a file entry by name in the archive.
    public func Find(_ name: string) -> File? {
        for f in Files {
            if f.Name == name {
                return f
            }
        }
        return nil
    }
}
