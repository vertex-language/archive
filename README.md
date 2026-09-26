# archive

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)
[![formats: zip | tar](https://img.shields.io/badge/formats-zip%20%7C%20tar-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language/archive)
[![compression: store | deflate](https://img.shields.io/badge/compression-store%20%7C%20deflate-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language/archive)
[![status: tested](https://img.shields.io/badge/status-tested-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language/archive)

Standard archive formats: production-grade readers and writers for TAR (POSIX.1-1988 USTAR) and ZIP (PKWARE APPNOTE / RFC 1951 DEFLATE), composing natively with `io` streaming protocols.

> **Status.** Implementations of `archive/tar` and `archive/zip` with zero
> external dependencies. The full test suite in `cmd/check` passes (45 checks)
> covering round-trip serialization, stream extraction, CRC-32 verification,
> directory structures, and error recovery.

---

## Why

Archiving packages files, directories, and metadata into single portable byte streams:
- **`archive/tar`** provides linear streaming archive processing over `io.Reader`
  and `io.Writer`. It requires no random access or seeking, making it the ideal
  transport for network sockets, pipes, and compressed tarballs (`.tar.gz`).
- **`archive/zip`** provides random-access central-directory index parsing,
  transparent RFC 1951 raw DEFLATE compression and decompression, and IEEE 802.3
  CRC-32 checksum integrity verification.

**Zero native dependencies.** Both TAR and ZIP parsers, the DEFLATE engine,
and the CRC-32 table run identically on macOS (ARM64) and Windows (x86-64).

---

## Packages

| Package | Import Path | Format Spec | Primary Use Cases |
| --- | --- | --- | --- |
| **`tar`** | `import "archive/tar"` | POSIX.1-1988 USTAR / GNU | Streaming archives, backups, container layers, tarballs |
| **`zip`** | `import "archive/zip"` | PKWARE / RFC 1951 DEFLATE | Zip archives, document packages, model checkpoints, asset bundles |

---

## Design Rules

1. **Direct `io` Protocol Conformance.**
   - `tar.Reader` conforms to `io.Reader`: reading from the reader streams
     the currently selected file's payload byte-by-byte without buffering the
     whole file in memory.
   - `tar.Writer` conforms to `io.Writer` and `io.Closer`: file contents are
     streamed directly into the underlying writer, and closing emits the two
     standard 512-byte zero padding blocks.
   - `zip.Reader` and `zip.Writer` operate directly over `io.Reader`,
     `io.Seeker`, `io.Writer`, and `io.Cursor`.
2. **Streaming TAR without Arbitrary In-Memory Buffers.**
   `tar.Reader.Next()` advances past any unread bytes of the previous file,
   aligns to the 512-byte block boundary, and decodes the next header. Large
   multi-gigabyte archives can be parsed with $O(1)$ memory.
3. **Strict Checksum & Boundary Integrity.**
   - TAR headers validate the unsigned 8-byte octal checksum over all 512 header
     bytes (with the checksum field treated as ASCII spaces).
   - ZIP file extraction validates both the uncompressed byte count and the
     IEEE 802.3 CRC-32 checksum. Corrupted archives throw `ZipError.checksumMismatch`.
4. **Clean Error Model.**
   Errors are strongly typed enums (`TarError`, `ZipError`) conforming to
   `Error`, `Equatable`, and `CustomStringConvertible`, providing descriptive
   diagnostic messages on truncated headers, unexpected EOFs, or unsupported
   compression algorithms.
5. **No Shelling Out or Native Bridges.**
   Archives can be unpacked and assembled freestanding without `libarchive`,
   `zlib.so`, or external command invocations.

---

## Quick Start

Run any entry point with:

```bash
vsc run main.vs
```

### 1. Writing a TAR Archive

```swift
package main

import "archive/tar"
import "io"

func main() -> int32 {
    var output = io.Cursor()
    var writer = tar.Writer(&output)

    // Write a regular file
    var header = tar.Header(
        name: "hello.txt",
        size: 13,
        mode: 0o644,
        typeflag: .regular
    )
    try! writer.WriteHeader(header)
    try! io.WriteText(&writer, "Hello, Vertex")

    // Write a directory
    var dirHeader = tar.Header(
        name: "data/",
        size: 0,
        mode: 0o755,
        typeflag: .directory
    )
    try! writer.WriteHeader(dirHeader)

    // Finalize the archive (emits two 512-byte zero blocks)
    try! writer.Close()

    print("Created TAR archive: \(output.Bytes.count) bytes")
    return 0
}
```

### 2. Reading and Extracting a TAR Archive

```swift
package main

import "archive/tar"
import "io"

func main() -> int32 {
    var input = io.Cursor(archiveBytes)
    var reader = tar.Reader(&input)

    while let header = try! reader.Next() {
        print("Found: \(header.Name) (\(header.Size) bytes, type: \(header.Typeflag))")
        if header.Typeflag == .regular {
            let content = try! reader.ReadAll()
            print("Payload: \(string(content))")
        }
    }
    return 0
}
```

### 3. Creating a ZIP Archive (Store and Deflate)

```swift
package main

import "archive/zip"
import "io"

func main() -> int32 {
    var output = io.Cursor()
    var writer = zip.Writer(&output)

    // Add uncompressed file (Store)
    try! writer.Add(
        name: "manifest.json",
        data: Array("{\"version\": \"1.0.0\"}".utf8),
        method: .store
    )

    // Add compressed file (RFC 1951 DEFLATE)
    let largePayload = Array("Repeatable data string...".utf8)
    try! writer.Add(
        name: "data.txt",
        data: largePayload,
        method: .deflate
    )

    // Add directory entry
    try! writer.AddDir("models/")

    // Finalize central directory and EOCD record
    try! writer.Close()

    print("Created ZIP archive: \(output.Bytes.count) bytes")
    return 0
}
```

### 4. Reading a ZIP Archive & Extracting Entries

```swift
package main

import "archive/zip"

func main() -> int32 {
    let reader = try! zip.Reader(zipFileBytes)

    print("Archive contains \(reader.Files.count) files:")
    for file in reader.Files {
        print(" - \(file.Name): \(file.UncompressedSize) bytes (method: \(file.Method))")
    }

    if let file = reader.Find("manifest.json") {
        let content = try! file.Read()
        print("manifest.json content:\n\(string(content))")
    }

    return 0
}
```

---

## API Reference

### `archive/tar`

#### `struct Header`
Represents the 512-byte POSIX USTAR header:
- `var Name: string`: Path of the file.
- `var Mode: int64`: Unix permission bits (e.g. `0o644`, `0o755`).
- `var Uid: int`, `var Gid: int`: User and group IDs.
- `var Size: int64`: File size in bytes.
- `var ModTime: int64`: Last modification time (UNIX epoch seconds).
- `var Typeflag: FileType`: Entry classification (`.regular`, `.directory`, `.symlink`, `.link`).
- `var Linkname: string`: Target path if a link or symlink.
- `var Uname: string`, `var Gname: string`: Owner user and group names.
- `var Devmajor: int64`, `var Devminor: int64`: Device numbers.
- `var Prefix: string`: USTAR filename prefix for paths $> 100$ characters.

#### `enum FileType`
- `.regular` (`'0'` / `'\0'`)
- `.link` (`'1'`)
- `.symlink` (`'2'`)
- `.characterDevice` (`'3'`)
- `.blockDevice` (`'4'`)
- `.directory` (`'5'`)
- `.fifo` (`'6'`)
- `.contiguous` (`'7'`)

#### `struct Reader: io.Reader`
- `init(_ reader: any io.Reader)`
- `mutating func Next() throws -> Header?`: Advances to the next entry in the TAR stream.
- `mutating func Read(into buffer: inout [uint8]) throws -> int`: Reads up to the end of the current entry.
- `mutating func ReadAll() throws -> [uint8]`: Collects all remaining bytes of the current entry.

#### `struct Writer: io.Writer, io.Closer`
- `init(_ writer: any io.Writer)`
- `mutating func WriteHeader(_ header: Header) throws`: Emits the 512-byte header.
- `mutating func Write(_ bytes: borrowing [uint8]) throws`: Streams payload bytes for the active header.
- `mutating func Close() throws`: Writes trailing padding and the 1024-byte archive terminator.

---

### `archive/zip`

#### `enum Method`
- `.store` (`0`): Uncompressed raw bytes.
- `.deflate` (`8`): RFC 1951 DEFLATE compressed bytes.

#### `struct FileHeader`
- `var Name: string`: Filename (UTF-8 encoded).
- `var Comment: string`: Optional file comment.
- `var Method: Method`: Compression format (`.store` or `.deflate`).
- `var CRC32: uint32`: Standard IEEE 802.3 CRC-32 checksum.
- `var CompressedSize: int64`: Stored byte length in archive.
- `var UncompressedSize: int64`: Raw uncompressed byte length.
- `var ModifiedTime: uint16`, `var ModifiedDate: uint16`: MS-DOS format timestamp.
- `var ExternalAttributes: uint32`: Permissions and type flags (Unix mode in upper 16 bits).
- `var IsDir: bool`: True if name ends with `/` or directory attributes are set.

#### `struct File`
- `var Header: FileHeader`
- `var Name: string`
- `var CompressedSize: int64`
- `var UncompressedSize: int64`
- `var Method: Method`
- `var IsDir: bool`
- `func Read() throws -> [uint8]`: Decompresses (if needed) and verifies CRC-32 and size.

#### `struct Reader`
- `init(_ bytes: [uint8]) throws`: Initializes from memory byte array.
- `var Files: [File]`: List of all archived files.
- `var Comment: string`: Archive-level comment from EOCD.
- `func Find(_ name: string) -> File?`: Fast lookup by exact filename.

#### `struct Writer: io.Closer`
- `init(_ writer: any io.Writer)`
- `mutating func Add(name: string, data: [uint8], method: Method = .deflate) throws`: Writes a file entry with auto-compression and CRC calculation.
- `mutating func AddDir(name: string) throws`: Writes a directory entry.
- `mutating func Close() throws`: Writes central directory headers and the End of Central Directory record.

---

## Technical Specifications

### TAR (USTAR) Block Structure
Every record in a TAR file consists of one or more 512-byte blocks:
```
┌─────────────────────────────────────────────────────────────┐
│ Header Block (512 bytes: name, mode, size, checksum, magic) │
├─────────────────────────────────────────────────────────────┤
│ File Data Blocks (N * 512 bytes, zero-padded at end)        │
├─────────────────────────────────────────────────────────────┤
│ ... More Headers and Data Blocks ...                        │
├─────────────────────────────────────────────────────────────┤
│ End-of-Archive Terminator (2 * 512 bytes of binary zeros)   │
└─────────────────────────────────────────────────────────────┘
```

### ZIP File Layout
ZIP archives place the directory index at the tail of the stream for random-access lookups:
```
┌─────────────────────────────────────────────────────────────┐
│ Local File Header 1 + Payload 1                             │
├─────────────────────────────────────────────────────────────┤
│ Local File Header 2 + Payload 2                             │
├─────────────────────────────────────────────────────────────┤
│ ...                                                         │
├─────────────────────────────────────────────────────────────┤
│ Central Directory File Header 1                             │
├─────────────────────────────────────────────────────────────┤
│ Central Directory File Header 2                             │
├─────────────────────────────────────────────────────────────┤
│ End of Central Directory Record (EOCD: 0x06054b50)          │
└─────────────────────────────────────────────────────────────┘
```

---

## Verification & Testing

The archive test suite validates full compliance against standard toolchains:

```bash
# Run the test suite (cmd/check); the Desktop's vs.work finds ../io
vsc run check
```

Test coverage includes:
- **TAR**: Round-trip creation and extraction of single and multiple files.
- **TAR**: Directory handling and permission mode preservation.
- **TAR**: Alignment padding and dual 512-byte terminator verification.
- **TAR**: Checksum corruption detection and truncated header rejection.
- **ZIP**: Store (uncompressed) round-trip read/write.
- **ZIP**: RFC 1951 DEFLATE compression and decompression.
- **ZIP**: IEEE 802.3 CRC-32 integrity validation and mismatch rejection.
- **ZIP**: Central directory and End of Central Directory (EOCD) parsing.
- **ZIP**: Empty files, large payloads, and nested directory paths.

---

## License

[MIT](LICENSE)
