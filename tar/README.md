# archive/tar

Reads and writes TAR archives (POSIX.1-1988 USTAR, with GNU extensions) as a stream over `io` readers and writers. It needs no seeking, so it works over sockets, pipes, and `.tar.gz` files.

```vertex
import "archive/tar"
```

## Types

- **`TarError`** (enum): Errors encountered while reading or writing TAR archives.
- **`FileType`** (enum): The type of file entry stored in a TAR archive.
- **`Header`** (struct): A 512-byte POSIX.1-1988 USTAR TAR file header.
- **`Reader`** (struct): Reader provides streaming access to the entries of a TAR archive.
- **`Writer`** (struct): Writer provides streaming construction of a TAR archive.

Part of the [`archive`](https://github.com/vertex-language/archive) repository.
