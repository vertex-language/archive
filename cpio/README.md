# archive/cpio

Reads and writes cpio archives in the "newc" format (SVR4, magic 070701): what a Linux initramfs is.

```vertex
import "archive/cpio"
```

## Types

- **`ModeType`** (enum): The file type bits of a Mode (`S_IFMT` and its values).
- **`CpioError`** (enum)
- **`Header`** (struct): One entry's metadata.
- **`Writer`** (struct): Writer writes a newc archive: WriteHeader for each entry, then Write its Size bytes of data; Close writes the trailer.
- **`Reader`** (struct): Reader reads a newc archive: Next for each entry's header, then Read its data. Next returns nil at the trailer.

## Functions

- `func Padding(_ n: int64) -> int`: Zero bytes that bring `n` up to a multiple of four.

Part of the [`archive`](https://github.com/vertex-language/archive) repository.
