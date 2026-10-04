// archive test suite: comprehensive checks for archive/tar and archive/zip.
package main

import (
    "fs"
    "archive/cpio"
    "archive/tar"
    "archive/zip"
    "io"
)

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

/// A PAX record: "<len> key=value\n", the length counting itself.
func paxRecord(_ key: string, _ value: string) -> [uint8] {
    let body = " \(key)=\(value)\n"
    var n = body.utf8.count + 1
    while "\(n)".utf8.count + body.utf8.count != n { n += 1 }
    return [uint8]("\(n)\(body)".utf8)
}

/// PAX extended headers and GNU long names: the names and sizes they carry
/// reach the entry after them, and they aren't entries themselves.
func testTarExtensions() {
    do {
        var w = tar.Writer(io.Cursor())
        let long = "deep/" + string(repeating: "d", count: 120) + "/" + string(repeating: "f", count: 60) + ".txt"
        let pax = paxRecord("path", long) + paxRecord("mtime", "1700000000.25") + paxRecord("uid", "4294967294")
        try w.WriteHeader(tar.Header(name: "PaxHeaders/x", size: int64(pax.count), typeflag: .paxHeader))
        try w.Write(pax)
        let body = [uint8]("pax body".utf8)
        try w.WriteHeader(tar.Header(name: "truncated-name", size: int64(body.count)))
        try w.Write(body)

        let gnuName = "gnu/" + string(repeating: "g", count: 150)
        let nameBytes = [uint8](gnuName.utf8) + [0]
        try w.WriteHeader(tar.Header(name: "././@LongLink", size: int64(nameBytes.count), typeflag: .gnuLongName))
        try w.Write(nameBytes)
        try w.WriteHeader(tar.Header(name: "short", size: 0, typeflag: .symlink, linkname: "target"))

        try w.WriteHeader(tar.Header(name: "plain", size: 0))
        try w.Close()

        var r = tar.Reader(io.Cursor(w.Inner.Bytes))
        guard let a = try r.Next() else { check(false, "tar PAX entry"); return }
        check(a.Name == long, "tar PAX path replaces the 100-byte name")
        check(a.ModTime == 1700000000 && a.Uid == 4294967294, "tar PAX mtime and a uid too big for octal")
        check(try r.ReadAll() == body, "tar PAX entry's payload is its own, not the record's")
        guard let b = try r.Next() else { check(false, "tar GNU entry"); return }
        check(b.Name == gnuName && b.Typeflag == .symlink && b.Linkname == "target", "tar GNU long name reaches the next entry")
        guard let c = try r.Next() else { check(false, "tar entry after the extensions"); return }
        check(c.Name == "plain", "tar records apply to one entry only")
        check(try r.Next() == nil, "tar extension headers aren't entries")
    } catch {
        check(false, "tar extensions threw: \(error)")
    }
}

func testCpio() {
    do {
        var w = cpio.Writer(io.Cursor())
        try w.WriteHeader(cpio.Header(name: "bin", mode: cpio.ModeType.directory | 0o755, nlink: 2))
        let sh = [uint8]("#!/bin/sh\necho hi\n".utf8)
        try w.WriteHeader(cpio.Header(name: "bin/hello", mode: cpio.ModeType.regular | 0o755,
                                      uid: 1000, gid: 1000, modTime: 1700000000, size: int64(sh.count)))
        try w.Write(sh)
        let target = [uint8]("hello".utf8)
        try w.WriteHeader(cpio.Header(name: "bin/hi", mode: cpio.ModeType.symlink | 0o777, size: int64(target.count)))
        try w.Write(target)
        try w.WriteHeader(cpio.Header(name: "dev/console", mode: cpio.ModeType.charDevice | 0o600,
                                      rdevMajor: 5, rdevMinor: 1))
        try w.Close()
        let bytes = w.Inner.Bytes
        check(bytes.count % 4 == 0, "cpio archive is padded to four bytes")
        check(string(decoding: Array(bytes[0..<6]), as: UTF8.self) == "070701", "cpio starts with the newc magic")

        var r = cpio.Reader(io.Cursor(bytes))
        let d = try r.Next()
        check(d?.Name == "bin" && d?.Kind == cpio.ModeType.directory && d?.Nlink == 2, "cpio directory entry")
        let f = try r.Next()
        check(f?.Name == "bin/hello" && f?.Uid == 1000 && f?.ModTime == 1700000000 && f?.Mode == 0o100755,
              "cpio file header fields")
        check(try r.ReadAll() == sh, "cpio file data")
        let l = try r.Next()
        check(l?.Kind == cpio.ModeType.symlink && (try r.ReadAll()) == target, "cpio symlink target")
        let c = try r.Next()
        check(c?.Kind == cpio.ModeType.charDevice && c?.RdevMajor == 5 && c?.RdevMinor == 1, "cpio device numbers")
        check(try r.Next() == nil, "cpio ends at the trailer")
        let inodes = [d?.Inode ?? 0, f?.Inode ?? 0, l?.Inode ?? 0, c?.Inode ?? 0]
        check(Set(inodes).count == 4 && !inodes.contains(0), "cpio entries get distinct inodes")
    } catch {
        check(false, "cpio round trip threw \(error)")
    }
    do {
        var w = cpio.Writer(io.Cursor())
        try w.WriteHeader(cpio.Header(name: "a", mode: cpio.ModeType.regular | 0o644, size: 3))
        try w.Write([1, 2])
        try w.Close()
        check(false, "cpio refuses an entry cut short")
    } catch {
        check(true, "cpio refuses an entry cut short")
    }
}

/// zip.Archive: the same archive written to a file, streamed back entry
/// by entry with a small buffer.
func testZipArchiveFile() {
    do {
        var big = [uint8]()
        var x: uint32 = 1
        for i in 0..<300_000 {
            x = x &* 1103515245 &+ 12345
            big.append(i % 7 == 0 ? uint8(x >> 24) : uint8(i % 13))
        }
        var w = zip.Writer(io.Cursor())
        try w.Add(name: "big.bin", data: big, method: .deflate)
        try w.Add(name: "plain.txt", data: [uint8]("stored, not compressed".utf8), method: .store)
        try w.Add(name: "empty", data: [], method: .deflate)
        try w.Close()
        let dir = try fs.TempDir(prefix: "archive-check-")
        defer { try? fs.RemoveAll(dir) }
        let path = dir / "a.zip"
        try fs.WriteFile(path, w.Inner.Bytes)

        let a = try zip.Archive.Open(path.Value)
        defer { a.Close() }
        check(a.Files.count == 3, "zip archive file lists its entries")
        func readAll(_ name: string) throws -> [uint8] {
            guard let h = a.Find(name) else { throw zip.ZipError.fileNotFound(name) }
            var r = try a.Open(h)
            var out: [uint8] = []
            var buf = [uint8](repeating: 0, count: 4093)
            while true {
                let n = try r.Read(into: &buf)
                if n == 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            return out
        }
        check(try readAll("big.bin") == big, "zip archive file streams a deflated entry")
        check(try readAll("plain.txt") == [uint8]("stored, not compressed".utf8), "zip archive file streams a stored entry")
        check(try readAll("empty").isEmpty, "zip archive file streams an empty entry")

        // Flip a byte of the stored entry's payload: the CRC must catch it.
        var bad = w.Inner.Bytes
        let at = int(a.Find("plain.txt")!.LocalHeaderOffset) + 30 + "plain.txt".utf8.count
        bad[at] ^= 0xFF
        try fs.WriteFile(dir / "bad.zip", bad)
        let b = try zip.Archive.Open((dir / "bad.zip").Value)
        defer { b.Close() }
        var r = try b.Open(b.Find("plain.txt")!)
        var buf = [uint8](repeating: 0, count: 64)
        do {
            while try r.Read(into: &buf) > 0 {}
            check(false, "zip archive file catches a corrupt entry")
        } catch zip.ZipError.checksumMismatch(_, _) {
            check(true, "zip archive file catches a corrupt entry")
        }
    } catch {
        check(false, "zip archive file threw: \(error)")
    }
}

func main() -> int32 {
    print("Running CPIO tests...")
    testCpio()
    testTarExtensions()
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
    testZipArchiveFile()

    if failures > 0 {
        print("\(failures) checks failed")
        return 1
    }
    print("all passed")
    return 0
}
