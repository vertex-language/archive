# archive/zip

Reads and writes ZIP archives: random access through the central directory, DEFLATE compression and decompression, and CRC-32 integrity checks.

```vertex
import "archive/zip"
```

## Types

- **`ZipError`** (enum): Errors encountered while parsing, extracting, or creating ZIP archives.
- **`Method`** (enum): The compression method applied to an entry in a ZIP archive.
- **`FileHeader`** (struct): Metadata describing a file entry within a ZIP archive.
- **`File`** (struct): An individual file entry inside a ZIP archive.
- **`Reader`** (struct): Reader provides random-access inspection and extraction of ZIP archives.
- **`Writer`** (struct): Writer creates and formats ZIP archives streaming into an underlying io.Writer.

## Functions

- `func Update(_ crc: uint32, _ data: [uint8]) -> uint32`: Updates a running CRC-32 with additional data bytes using the IEEE 802.3 polynomial.
- `func Checksum(_ data: [uint8]) -> uint32`: Returns the IEEE 802.3 CRC-32 checksum of the given bytes.
- `func ChecksumString(_ s: string) -> uint32`: Returns the IEEE 802.3 CRC-32 checksum of a UTF-8 string.
- `func Inflate(_ data: [uint8], sizeHint: int = 0) throws -> [uint8]`: Decompresses raw RFC 1951 DEFLATE bytes into uncompressed data.
- `func Deflate(_ data: [uint8]) -> [uint8]`: Compresses uncompressed data into raw RFC 1951 DEFLATE bytes using fixed Huffman codes.

Part of the [`archive`](https://github.com/vertex-language/archive) repository.
