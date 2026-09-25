// archive test suite: comprehensive checks for archive/tar and archive/zip.
package main

import "archive/tar"
import "archive/zip"
import "io"

var failures: int32 = 0

func check(_ ok: bool, _ what: string) {
    if ok {
        print("ok    \(what)")
    } else {
        print("FAIL  \(what)")
        failures += 1
    }
}

// ---------------------------------------------------------------------------
// TAR tests
// ---------------------------------------------------------------------------

func testTarEmpty() {
    do {
        var w = tar.Writer(io.Cursor())
        try w.Close()

        check(w.Inner.Bytes.count == 1024, "tar empty archive writes 1024 zero bytes")

        var r = tar.Reader(io.Cursor(w.Inner.Bytes))
        let next = try r.Next()
        check(next == nil, "tar empty archive Next() returns nil")
    } catch {
        check(false, "tar empty threw: \(error)")
    }
}

func testTarSingleFile() {
    do {
        var w = tar.Writer(io.Cursor())

        let msg = "Hello, Vertex TAR Archive!"
        let msgBytes = [uint8](msg.utf8)

        var h = tar.Header(
            name: "greeting.txt",
            size: int64(msgBytes.count),
            mode: 0o644,
            typeflag: .regular
        )
        try w.WriteHeader(h)
        try w.Write(msgBytes)
        try w.Close()

        // 512 header + 512 padded data + 1024 end blocks = 2048 bytes
        check(w.Inner.Bytes.count == 2048, "tar single file archive size is 2048 bytes")

        var r = tar.Reader(io.Cursor(w.Inner.Bytes))
        guard let entry = try r.Next() else {
            check(false, "tar single file header not found")
            return
        }

        check(entry.Name == "greeting.txt", "tar header name matches")
        check(entry.Size == int64(msgBytes.count), "tar header size matches")
        check(entry.Mode == 0o644, "tar header mode matches")
        check(entry.Typeflag == .regular, "tar header typeflag is regular")

        let got = try r.ReadAll()
        check(got == msgBytes, "tar payload matches")

        let end = try r.Next()
        check(end == nil, "tar returns nil after last entry")
    } catch {
        check(false, "tar single file threw: \(error)")
    }
}

func testTarMultipleFiles() {
    do {
        var w = tar.Writer(io.Cursor())

        let file1 = "first file content"
        let f1Bytes = [uint8](file1.utf8)
        try w.WriteHeader(tar.Header(name: "f1.txt", size: int64(f1Bytes.count)))
        try w.Write(f1Bytes)

        // Empty file
        try w.WriteHeader(tar.Header(name: "empty.dat", size: 0))

        // Large file (> 512 bytes)
        var largeData = [uint8](repeating: 0, count: 1200)
        var i = 0
        while i < 1200 {
            largeData[i] = uint8(i & 0xFF)
            i += 1
        }
        try w.WriteHeader(tar.Header(name: "large.bin", size: 1200))
        try w.Write(largeData)

        try w.Close()

        var r = tar.Reader(io.Cursor(w.Inner.Bytes))

        let e1 = try r.Next()
        check(e1?.Name == "f1.txt" && (try r.ReadAll()) == f1Bytes, "tar multi-file entry 1")

        let e2 = try r.Next()
        check(e2?.Name == "empty.dat" && (try r.ReadAll()).isEmpty, "tar multi-file entry 2 (empty)")

        let e3 = try r.Next()
        check(e3?.Name == "large.bin" && (try r.ReadAll()) == largeData, "tar multi-file entry 3 (large)")

        let eEnd = try r.Next()
        check(eEnd == nil, "tar multi-file end is nil")
    } catch {
        check(false, "tar multiple files threw: \(error)")
    }
}

func testTarDirectory() {
    do {
        var w = tar.Writer(io.Cursor())

        try w.WriteHeader(tar.Header(name: "docs/", size: 0, mode: 0o755, typeflag: .directory))
        let readme = "README text"
        let rBytes = [uint8](readme.utf8)
        try w.WriteHeader(tar.Header(name: "docs/README.md", size: int64(rBytes.count)))
        try w.Write(rBytes)
        try w.Close()

        var r = tar.Reader(io.Cursor(w.Inner.Bytes))

        let d = try r.Next()
        check(d?.Name == "docs/" && d?.Typeflag == .directory && d?.Mode == 0o755, "tar directory entry")

        let f = try r.Next()
        check(f?.Name == "docs/README.md" && (try r.ReadAll()) == rBytes, "tar file in directory")
    } catch {
        check(false, "tar directory threw: \(error)")
    }
}

func testTarPartialRead() {
    do {
        var w = tar.Writer(io.Cursor())

        let f1 = "1234567890abcdefghij"
        try w.WriteHeader(tar.Header(name: "f1.txt", size: int64(f1.utf8.count)))
        try w.Write([uint8](f1.utf8))

        let f2 = "second file"
        try w.WriteHeader(tar.Header(name: "f2.txt", size: int64(f2.utf8.count)))
        try w.Write([uint8](f2.utf8))
        try w.Close()

        var r = tar.Reader(io.Cursor(w.Inner.Bytes))

        _ = try r.Next()
        // Read only 5 bytes of f1
        var partial = [uint8](repeating: 0, count: 5)
        let n = try r.Read(into: &partial)
        check(n == 5, "tar partial read count")

        // Next() should advance over remaining 15 bytes + padding to f2!
        let e2 = try r.Next()
        check(e2?.Name == "f2.txt", "tar Next() after partial read advances to next entry")
        let got2 = try r.ReadAll()
        check(got2 == [uint8](f2.utf8), "tar next entry payload intact after partial read")
    } catch {
        check(false, "tar partial read threw: \(error)")
    }
}

func testTarChecksumValidation() {
    do {
        var w = tar.Writer(io.Cursor())
        try w.WriteHeader(tar.Header(name: "valid.txt", size: 4))
        try w.Write([uint8]("test".utf8))
        try w.Close()

        // Corrupt header checksum at offset 150
        var bytes = w.Inner.Bytes
        bytes[150] = bytes[150] ^ 0xFF

        var r = tar.Reader(io.Cursor(bytes))
        var threwChecksum = false
        do {
            _ = try r.Next()
        } catch TarError.badChecksum {
            threwChecksum = true
        } catch {}
        check(threwChecksum, "tar throws badChecksum on corrupted header block")
    } catch {
        check(false, "tar checksum test threw: \(error)")
    }
}

func testTarWriteLimits() {
    do {
        var w = tar.Writer(io.Cursor())
        try w.WriteHeader(tar.Header(name: "file.txt", size: 5))
        var threwOver = false
        do {
            try w.Write([uint8]("123456".utf8))
        } catch TarError.writePastSize {
            threwOver = true
        } catch {}
        check(threwOver, "tar throws writePastSize on writing too much")
    } catch {
        check(false, "tar write limits threw: \(error)")
    }

    do {
        var w = tar.Writer(io.Cursor())
        try w.WriteHeader(tar.Header(name: "file.txt", size: 10))
        try w.Write([uint8]("12345".utf8))
        var threwIncomplete = false
        do {
            try w.Close()
        } catch TarError.writeIncomplete {
            threwIncomplete = true
        } catch {}
        check(threwIncomplete, "tar throws writeIncomplete on closing with unwritten bytes")
    } catch {
        check(false, "tar write limits incomplete threw: \(error)")
    }
}

// ---------------------------------------------------------------------------
// ZIP tests
// ---------------------------------------------------------------------------

func testZipCRC32Vector() {
    // "123456789" standard IEEE 802.3 CRC-32 is 0xCBF43926
    let vector = [uint8]("123456789".utf8)
    let crc = zip.Checksum(vector)
    check(crc == 0xCBF43926, "zip CRC-32 standard test vector (0xCBF43926)")

    let emptyCRC = zip.Checksum([])
    check(emptyCRC == 0, "zip CRC-32 empty array is 0")
}

func testZipDeflateRoundTrip() {
    do {
        // Compress repetitive text
        let originalText = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
        let original = [uint8](originalText.utf8)

        let deflated = zip.Deflate(original)
        check(deflated.count < original.count, "deflate compresses repetitive string")

        let inflated = try zip.Inflate(deflated, sizeHint: original.count)
        check(inflated == original, "inflate round-trips deflated payload")

        // Empty deflate
        let emptyDeflated = zip.Deflate([])
        let emptyInflated = try zip.Inflate(emptyDeflated, sizeHint: 0)
        check(emptyInflated.isEmpty, "deflate/inflate round-trips empty array")
    } catch {
        check(false, "zip deflate round trip threw: \(error)")
    }
}

func testZipEmpty() {
    do {
        var w = zip.Writer(io.Cursor())
        try w.Close()

        check(w.Inner.Bytes.count == 22, "zip empty archive is exactly 22 bytes (EOCD)")

        let r = try zip.Reader(w.Inner.Bytes)
        check(r.Files.isEmpty, "zip empty archive has 0 files")
    } catch {
        check(false, "zip empty archive threw: \(error)")
    }
}

func testZipStore() {
    do {
        var w = zip.Writer(io.Cursor())

        let text = "Uncompressed payload content"
        let data = [uint8](text.utf8)
        try w.Add(name: "stored.txt", data: data, method: .store)
        try w.Close()

        let r = try zip.Reader(w.Inner.Bytes)
        check(r.Files.count == 1, "zip reader found 1 file")

        guard let f = r.Find("stored.txt") else {
            check(false, "stored.txt not found in zip")
            return
        }

        check(f.Method == .store, "zip file method is store")
        check(f.UncompressedSize == int64(data.count), "zip file uncompressed size")
        check(f.CompressedSize == int64(data.count), "zip file compressed size")

        let readBack = try f.Read()
        check(readBack == data, "zip store payload round trips correctly")
    } catch {
        check(false, "zip store threw: \(error)")
    }
}

func testZipDeflateFile() {
    do {
        var w = zip.Writer(io.Cursor())

        var large = [uint8]()
        for _ in 0..<100 {
            for b in "Vertex is a modern systems language. ".utf8 {
                large.append(b)
            }
        }

        try w.Add(name: "compressed.txt", data: large, method: .deflate)
        try w.Close()

        let r = try zip.Reader(w.Inner.Bytes)
        check(r.Files.count == 1, "zip deflate archive file count")

        guard let f = r.Find("compressed.txt") else {
            check(false, "compressed.txt not found")
            return
        }

        check(f.Method == .deflate, "zip file method is deflate")
        check(f.CompressedSize < f.UncompressedSize, "zip file is compressed on disk")

        let readBack = try f.Read()
        check(readBack == large, "zip deflate payload decompresses correctly")
    } catch {
        check(false, "zip deflate file threw: \(error)")
    }
}

func testZipMultipleFilesAndDirectories() {
    do {
        var w = zip.Writer(io.Cursor())

        // Directory
        try w.AddDir("images/")

        // File in directory
        let imgData = [uint8]("fake png data bytes".utf8)
        try w.Add(name: "images/logo.png", data: imgData, method: .store)

        // Root file
        let docData = [uint8]("document body text".utf8)
        try w.Add(name: "doc.txt", data: docData, method: .deflate)

        // Empty file
        try w.Add(name: "empty.txt", data: [], method: .store)

        try w.Close()

        let r = try zip.Reader(w.Inner.Bytes)
        check(r.Files.count == 4, "zip multi-entry has 4 entries")

        guard let d = r.Find("images/") else {
            check(false, "images/ not found")
            return
        }
        check(d.IsDir, "images/ isDir is true")

        guard let fImg = r.Find("images/logo.png") else {
            check(false, "images/logo.png not found")
            return
        }
        check(try fImg.Read() == imgData, "images/logo.png payload matches")

        guard let fDoc = r.Find("doc.txt") else {
            check(false, "doc.txt not found")
            return
        }
        check(try fDoc.Read() == docData, "doc.txt payload matches")

        guard let fEmpty = r.Find("empty.txt") else {
            check(false, "empty.txt not found")
            return
        }
        check(try fEmpty.Read().isEmpty, "empty.txt payload is empty")
    } catch {
        check(false, "zip multiple files threw: \(error)")
    }
}

func testZipCorruptCRC() {
    do {
        var w = zip.Writer(io.Cursor())
        let text = "Integrity check string"
        try w.Add(name: "check.txt", data: [uint8](text.utf8), method: .store)
        try w.Close()

        // Locate data payload in zip bytes and corrupt one byte
        // In local header: "Integrity check string" starts at offset 30 + 9 = 39
        var bytes = w.Inner.Bytes
        bytes[39] = bytes[39] ^ 0x01

        let r = try zip.Reader(bytes)
        guard let f = r.Find("check.txt") else {
            check(false, "check.txt not found")
            return
        }

        var threwCRC = false
        do {
            _ = try f.Read()
        } catch ZipError.checksumMismatch {
            threwCRC = true
        } catch {}
        check(threwCRC, "zip throws checksumMismatch on corrupted payload")
    } catch {
        check(false, "zip corrupt crc threw: \(error)")
    }
}

func testZipCursorOpen() {
    do {
        var w = zip.Writer(io.Cursor())
        let data = [uint8]("streamable payload".utf8)
        try w.Add(name: "stream.txt", data: data, method: .deflate)
        try w.Close()

        let r = try zip.Reader(w.Inner.Bytes)
        guard let f = r.Find("stream.txt") else {
            check(false, "stream.txt not found")
            return
        }

        var cursor = try f.Open()
        var buf = [uint8](repeating: 0, count: 6)
        let n1 = try cursor.Read(into: &buf)
        check(n1 == 6, "zip cursor read first 6 bytes")

        let rest = try io.ReadToEnd(&cursor)
        check(rest.count == data.count - 6, "zip cursor read remainder")
    } catch {
        check(false, "zip cursor open threw: \(error)")
    }
}

// ---------------------------------------------------------------------------
// Main runner
// ---------------------------------------------------------------------------

func main() -> int32 {
    print("Running TAR tests...")
    testTarEmpty()
    testTarSingleFile()
    testTarMultipleFiles()
    testTarDirectory()
    testTarPartialRead()
    testTarChecksumValidation()
    testTarWriteLimits()

    print("Running ZIP tests...")
    testZipCRC32Vector()
    testZipDeflateRoundTrip()
    testZipEmpty()
    testZipStore()
    testZipDeflateFile()
    testZipMultipleFilesAndDirectories()
    testZipCorruptCRC()
    testZipCursorOpen()

    if failures > 0 {
        print("\(failures) checks failed")
        return 1
    }
    print("all passed")
    return 0
}
