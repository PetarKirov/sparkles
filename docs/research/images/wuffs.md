# Wuffs (Wuffs, C)

A memory-safe, hermetic language for "Wrangling Untrusted File Formats Safely",
with a standard library of image, compression and checksum codecs written in it and
transpiled to one C file; the catalog's reference for suspendable, allocation-free,
hostile-input-safe decoding and for what a binary description format would have to
express to describe a real decoder.

| Field         | Value                                                                                                                                                                                                                                                                                        |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Wuffs (compiler and tools in Go), transpiled to C99 with C++ auxiliary code                                                                                                                                                                                                                  |
| License       | Apache-2.0 OR MIT (`LICENSE`, `LICENSE-APACHE`, `LICENSE-MIT`; the [changelog][changelog] records the change from Apache-2.0 alone)                                                                                                                                                          |
| Repository    | [google/wuffs][repo]                                                                                                                                                                                                                                                                         |
| Revision read | `4be865da258c4b5e6d3e716fd4f36be016496a46` (October 21, 2026; the [snapshot version macros][snapshot-version] report `WUFFS_VERSION_STRING "0.0.0+0.00000000"` and pre-release label `"unsupported.snapshot"`; the [release README][release-readme] names v0.3 as the latest stable version) |
| Documentation | [`doc/`][doc] (language and library overviews), [`doc/note/`][doc-note] (short design notes), [`doc/std/`][doc-std] (API categories), [`doc/benchmarks.md`][bench]                                                                                                                           |
| Category      | Formats: safe codec language and standard library                                                                                                                                                                                                                                            |
| Tier          | A                                                                                                                                                                                                                                                                                            |
| Last reviewed | November 15, 2026                                                                                                                                                                                                                                                                            |

> [!IMPORTANT]
> **What was run.** The verifier reran claims marked **verified** against the pinned
> snapshot and `test/data/` using GCC 16.2.0 and LDC 1.43.0. Full PNG decoding from D
> passed with both a GCC implementation and an ImportC-built scalar implementation.
> The probes lived under `/tmp/wuffs-verifier`, using
> `nix develop /home/petar/code/repos/mine/sparkles-images -c`; they are not CI fixtures.
> Other upstream claims were checked with `git show`. Throughput figures are upstream
> measurements from [`doc/benchmarks.md`][bench], not measurements made here.

---

## Overview

### What it solves

Wuffs targets parsers exposed to malicious input. Its language checks safety in
three bug classes at compile time, eliminating those run-time checks in inner loops.
The [README][readme-safety] states the claim:

> "However, unlike hand-written C, Wuffs the Language is safe with respect to
> buffer overflows, integer arithmetic overflows and null pointer dereferences. A
> key difference between Wuffs and other memory-safe languages is that **all such
> checks are done at compile time, not at run time**. If it compiles, it is safe,
> with respect to those three bug classes."

The standard library (`std/`) holds the codecs. The
[image decoders][image-decoders-impls] are BMP, ETC2, GIF, Handsum, JPEG (baseline
and progressive), Netpbm, NIE, PNG (with APNG), QOI, Targa, ThumbHash, VP8, WBMP and
WebP (lossless VP8L and, through `std/vp8`, lossy). The
[compression decoders][compression-decoders] are bzip2, deflate, gzip, lzip, LZMA,
LZW, XZ and zlib; the hashers include Adler-32, CRC-32, CRC-64, SHA-256 and
xxHash; `std/json` and `std/cbor` are token decoders. There is no encoder in `std/`
at this revision. According to the [README][readme-status], Wuffs' GIF decoder has
shipped in Chrome since June 2021 (milestone M93); Skia's `SkWuffsCodec` is the
integration (see [Skia][skia]).

### Design philosophy

Wuffs gives up power to make proof easy. The [hermeticity note][hermeticity] lists
what the language lacks: "no mutable global variables", "no `unsafe` keyword", "no
FFI", "no user-supplied callbacks", "no system calls", "no allocation or
de-allocation of memory" and "no panicking or throwing exceptions", and ends
"**with less power comes easier proof of safety**". Ownership is one rule
([`memory-safety.md`][memsafety-owner]):

> "When a Wuffs decompressor reads from or writes to a buffer, that buffer has to be
> passed on every call, instead of being passed once during initialization and saved
> to a field. There is no ambiguity about whether the caller or callee should free
> some memory, even when encountering an error. It's always caller-owned and
> callee-borrowed."

The I/O consequence is [Sans I/O][sans-io]: the library computes, the caller reads
files and sockets, so the same decoder serves synchronous and asynchronous programs
([README][readme-hermetic]). The cost is admitted: programs "take longer for a
programmer to write, as they have to **explicitly annotate their programs with
proofs of safety**" ([README][readme-safety]). The proof checker is deliberately
simple: "a proof checker, not an SMT solver or automated theorem prover ... the
Wuffs compiler is fast (and dumb) instead of smart (and slow)"
([`assertions.md`][assertions-axioms]).

---

## How it works

### Proof by facts, refinements and intervals

Every index, slice and arithmetic expression must be proved in range. Three sources
feed the proof ([`bounds-checking.md`][bounds]): refinement types such as
`base.u32[..= 100]`, facts created by `if` and `while` conditions or by assignment
([`facts.md`][facts]), and integer interval arithmetic over expressions
([`interval-arithmetic.md`][interval]). A masked index such as `a[expr & 1023]` on
an `array[1024] base.u8` is in bounds by interval arithmetic alone; a slice index
needs a dynamic fact from a condition. Loops are not inferred: "Wuffs simply
requires the programmer to write exactly what the situation is, before and after
the loop" with `pre`, `inv` and `post` clauses ([`facts.md`][facts-loops]). Facts
that the checker cannot derive are stated with `assert ... via "axiom"`, where the
axiom is a named rule from a fixed list ([`axioms.md`][axioms]). Overflow uses the
same machinery; wrapping and saturating arithmetic are explicit operators (`~mod+`,
`~sat-`). The README's own example of a rejected one-line edit prints the failing
interval and the facts in scope ([README][readme-example]).

### Effects, coroutines and statuses

Functions are pure, impure (`!`) or coroutines (`?`); sub-expressions must be pure
([`effects.md`][effects]). A coroutine may suspend by returning a suspension
status; "Calling that function again will resume that function where it left off"
([`coroutines.md`][coroutines]). Coroutines are methods, their state
lives in the receiver struct, and they may call other coroutines but not
recursively. Crossing a suspension point "drops any facts involving `this` or
`args`", so proofs must be re-established after each one.

A status is a statically allocated C string whose first byte gives its category
([`statuses.md`][statuses]): `ok` (null), `@` note ("completed, unsuccessfully",
for example `"@end of data"`), `$` suspension ("not completed, but can be
re-tried") and `#` error ("not completed, permanently"). Errors are sticky: later
status-returning calls return `"#disabled by previous error"`. Ordinary I/O uses
`"$short read"` when the source is empty and `"$short write"` when the
destination is full ([`coroutines.md`][coroutines-io]); metadata passthrough also
uses `"$even more information"` ([`metadata.md`][metadata]).

The transpiler lowers coroutines to a `switch` over a resume point, Duff's-device
style ([`fundamental-private.h`][coro-macros]):

```c
#define WUFFS_BASE__COROUTINE_SUSPENSION_POINT(n) \
  coro_susp_point = n;                            \
  case n:;
```

A multi-byte read that straddles a suspension accumulates bytes in a per-coroutine
`scratch` field in the receiver; in the generated zlib header read, a 2-byte
`read_u16be` takes a fast `peek_u16be__no_bounds_check` path when two bytes are
available and otherwise loops one byte at a time, suspending with `short_read` and
resuming at the same `case` ([generated zlib read][zlib-generated] in the
[snapshot, available as a raw download][snapshot]
from [`decode_zlib.wuffs`][zlib-transform]).

### I/O buffers, readers and writers

An `io_buffer` is a byte slice plus `ri`, `wi`, `pos` and `closed`
([`io-public.h`][io-meta]; [`io-input-output.md`][io-buffers]), with the invariant
`((0 <= ri) and (ri <= wi) and (wi <= len))`. `pos` makes the buffer a sliding
window over a stream, so `pos + ri` is an absolute stream position; compaction
moves unread bytes to the front without changing it. `closed` separates "need more
bytes" from truncation ([`io-input-output.md`][io-closed]): with fewer bytes than a
read needs, an open buffer suspends and a closed one is an error. Wuffs code sees a
buffer only as a `base.io_reader` or `base.io_writer`, and "`ri` and `wi` will
never be decremented ... to be less than the initial values at the time of the
call" ([`io-input-output.md`][io-undo]). Two block constructs adapt buffers inside
Wuffs code: `io_bind` presents a slice as a reader or writer, and `io_limit` caps
how much of a reader a callee may consume. Readers expose `mark()`, `since(mark:)`
and `count_since(mark:)`, which return the bytes or count consumed since a mark;
the checksum code below is built on them.

Token streams are the non-pixel output form: a token is a `uint64_t` with a 16-bit
length, a `continued` bit and 47 value bits, and "The tokens partition the bytes"
([`tokens.md`][tokens]). The JSON decoder is a pull tokenizer for this reason.

### The image decoder interface

Every image decoder implements `base.image_decoder`
([`image-decoders.md`][image-decoders-api]); the core methods are:

```text
decode_image_config?(dst: nptr image_config, src: io_reader)
decode_frame_config?(dst: nptr frame_config, src: io_reader)
decode_frame?(dst: ptr pixel_buffer, src: io_reader, blend: pixel_blend,
              workbuf: slice u8, opts: nptr decode_frame_options)
workbuf_len() range_ii_u64
restart_frame!(index: u64, io_position: u64) status
set_quirk!(key: u32, value: u64) status
set_report_metadata!(fourcc: u32, report: bool)
tell_me_more?(dst: io_writer, minfo: nptr more_information, src: io_reader)
```

The canonical sequence is DIC, then pairs of DFC and DF, then a final DFC that
returns `"@end of data"` ([call sequence][call-seq]). A still image is the case
N = 1. Calls may be skipped and are then made implicitly: calling DF first runs DIC
and DFC #0; calling only DFC in a loop counts frames while skipping, not
decompressing, pixel data. A private `call_sequence` byte tracks the state (`0x00`,
`0x20`, `0x40`, `0x60`, with `0x10` for metadata detours and `0x08` for restarts)
and rejects out-of-order calls with `"#bad call sequence"`. `restart_frame` jumps to
frame `i` once the caller has positioned the reader at the `io_position` that frame's
`frame_config` recorded.

Memory is negotiated, not taken. DIC returns dimensions and a pixel format; the
caller allocates the pixel buffer or reports the image as too large to decode
([`memory-safety.md`][memsafety-api]); `workbuf_len()` returns an inclusive
range of scratch bytes. For PNG the range is exact, `height * (1 + bytes_per_row)`,
with non-interlaced PNG inflated as a whole before unfiltering; Adam7 is inflated
and unfiltered one pass at a time ([`decode_png.wuffs`][png-frame],
[`decode_ihdr`][png-ihdr], [`workbuf_len`][png-workbuf]). JPEG's
range has a lower bound of `0` when the lower-quality option is set and the file
is not progressive (`sof_marker < 0xC2`) ([`decode_jpeg.wuffs`][jpeg-workbuf]). The decoder object itself is opaque in C:
callers ask `sizeof__wuffs_png__decoder()` and call `wuffs_png__decoder__initialize`
with that size and `WUFFS_VERSION`, and there is no destructor
([`initialization.md`][init]).

Decoded pixels go through the **pixel swizzler**, which converts and composites
from the codec's source format to a supported destination format and blend the caller
chose (`wuffs_base__pixel_swizzler__prepare` selects one function pointer per
destination format, source format and blend; [`pixconv-submodule-regular.c`][swizzler-prepare]).
The swizzler is hand-written C in the `base` package, not Wuffs; the
[`base` README][cgen-base-readme] says pixel and string conversion "sometimes require
programming language features (e.g. function-pointer typed variables, SIMD
acceleration) that are not yet available in Wuffs-the-language".

### A PNG decode, end to end

The PNG decoder shows every mechanism at once.

- **Magic and header as numbers.** The 8-byte signature is read as one
  little-endian `u64` and compared with `'\x89PNG\x0D\x0A\x1A\x0A'le`; the next
  8 bytes must equal `'\x00\x00\x00\x0DIHDR'le`, and Apple's `CgBI` variant is named
  and refused ([`decode_png.wuffs`][png-dic]).
- **Checksums across suspensions.** Before each critical chunk body the decoder resets
  `crc32` and feeds the 4 type bytes; the body is parsed in a loop that marks the
  reader, calls the sub-parser, hashes `args.src.since(mark: mark)`, and only then
  yields on suspension. The CRC therefore covers exactly the consumed bytes however
  the input was split. Critical chunks are verified; ancillary chunk CRCs are
  skipped; the source contrasts this with libpng's "warns and discards" default,
  which also continues image decoding
  ([`decode_png.wuffs`][png-chunks]).
- **Validation in the reader.** `decode_ihdr` rejects zero or `> 0x7FFF_FFFF`
  dimensions as `"#bad header"` and anything above `0xFF_FFFF` as
  `"#unsupported image dimension"`, checks depth, colour type, compression, filter
  and interlace bytes, and derives `overall_workbuf_length` ([`decode_png.wuffs`][png-ihdr]).
- **Decompression inside chained chunks.** `decode_pass` binds the work buffer as a
  writer, wraps the source in `io_limit (io: args.src, limit: chunk_length)`, and
  runs `zlib.transform_io?` inside it. When the chunk is exhausted with zlib still
  wanting input, it verifies an `IDAT` chunk's CRC, reads the next chunk header, insists
  on another `IDAT` (or `fdAT` with the next animation sequence number), resets the
  CRC for `IDAT` (ancillary `fdAT` CRCs are skipped) and continues the same zlib stream. A stream that ends with chunk bytes left
  is `"#too much data"`, one that fills less than the work buffer is
  `"#not enough data"` ([`decode_png.wuffs`][png-pass]).
- **Two checksums, two directions.** PNG's CRC-32 covers compressed input
  (`src.since`); zlib's Adler-32 covers decompressed output, hashed from
  `args.dst.since(mark: mark)` after each deflate call ([`decode_zlib.wuffs`][zlib-transform]).
- **Policy as quirks.** `WUFFS_BASE__QUIRK_IGNORE_CHECKSUM` skips both
  ([`quirks.md`][quirks-list]); PNG forwards it to its inner zlib decoder.

**Verified** with the scratch program on `test/data/hippopotamus.regular.png` (36 by
28, RGB, one `IDAT` of 2,086 bytes): a whole-buffer decode, a decode fed 1 byte at a
time through a 16-byte compacted source buffer (40 DIC suspensions, 2,090 DF
suspensions) and a 7-byte feed all produced the same pixel hash, and `workbuf_len()`
was `[3052..3052]` (28 × (1 + 36 × 3)). The Adam7 file `hippopotamus.interlaced.png`
decoded to the same pixel hash under both feeds. `sizeof__wuffs_png__decoder()` was
44,648 bytes.

### What a binary description format would have to express

This is the Q4 question asked of `sparkles:wired`. Each row is a behaviour a Wuffs
decoder implements in code, with where it is shown; the last column is the Flat
draft's position as recorded in the [wired baseline][bl-wired] (G2 to G6).
The verifier checked the named rules, byte order, offset widths and O9 at the
baseline's pinned draft `8a454ce151c23b3608467cf8e19821678583ecb3`.
"Not described" records the baseline's scope, not a demonstrated impossibility.

| Requirement                                                                                                                          | Wuffs evidence                                                                                                                                           | Flat draft per the baseline                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Fixed-width integers with per-field byte order; magic values compared as numbers                                                     | `read_u32be`, `read_u64le`, `'IHDR'le` constants ([PNG][png-dic])                                                                                        | fixed integers yes; byte order fixed at compile time (G5)                     |
| Bit fields that cross byte boundaries, LSB-first (deflate) and MSB-first (JPEG), with refill state kept between calls                | `bits`, `n_bits` fields ([deflate][deflate-bits]); `bitstream_bits`, `bitstream_n_bits` ([JPEG][jpeg-bitstream])                                         | only ranges inside one leaf of at most 64 bits (`WFL27`); excluded by O9 (G2) |
| Field predicates and cross-field arithmetic checks                                                                                   | zlib `x % 31`, compression method and window ([zlib][zlib-transform]); stored-block `LEN + NLEN == 0xFFFF` ([deflate][deflate-blocks])                   | checks on the decoded fixed part (`WFL28`)                                    |
| A length prefix that scopes a sub-reader whose bytes another decoder consumes                                                        | `io_limit (io: args.src, limit: chunk_length)` around `zlib.transform_io?` ([PNG][png-pass])                                                             | not described in the baseline                                                 |
| Checksums over a byte range, on compressed input or on decompressed output, computed incrementally across suspensions                | CRC-32 over type plus body via `mark`/`since` ([PNG][png-chunks]); Adler-32 over `dst.since` ([zlib][zlib-transform])                                    | a check cannot see payload bytes (`WFL20`, G4)                                |
| One logical stream chained across several framed chunks, per-chunk checksums reset, decompressor state continuing                    | `IDAT`…`IDAT`, `fdAT` sequence numbers ([PNG][png-pass]); GIF sub-blocks of at most 255 bytes ending in a zero length ([GIF][gif-blocks])                | sequential self-sized arrays (`WFL33`); no stream continuation                |
| Escape removal before the bit reader sees data                                                                                       | JPEG `0xFF 0x00` unstuffing, fill bytes, marker detection and implicit zero padding into a 2 KiB buffer ([JPEG][jpeg-fill])                              | not described                                                                 |
| Suspendable reads at any field, including multi-byte fields split across buffers, and a truncation outcome distinct from "need more" | `scratch` accumulation ([generated zlib][zlib-generated]), `"$short read"` versus `closed` ([I/O][io-closed])                                            | `truncated` is terminal; no short-read status (G3)                            |
| Absolute stream positions for seeking and restarts                                                                                   | `pos + ri`, `restart_frame(index, io_position)` ([I/O][io-position], [call sequence][call-seq])                                                          | offsets of at most 32 bits (G5)                                               |
| Ordering rules between chunk kinds                                                                                                   | WebP `variant` bits track `VP8X`, `ICCP`, `ANIM`, `ANMF`, `ALPH` order ([WebP][webp-variant]); PNG `acTL`/`fcTL`/`IDAT`/`fdAT` rules ([PNG][png-chunks]) | not described                                                                 |
| Output-size contracts derived from header fields                                                                                     | `workbuf_len` = `height * (1 + bytes_per_row)` ([IHDR][png-ihdr]); "too much" and "not enough" data errors ([PNG][png-pass])                             | budgets are traversal bytes and depth (G8)                                    |
| Metadata reported as stream ranges or as transformed bytes                                                                           | raw passthrough ranges for `eXIf`, zlib-inflated `iCCP` ([`metadata.md`][metadata], [PNG][png-iccp])                                                     | not described                                                                 |
| Acceptance policy switches                                                                                                           | quirks, including `IGNORE_CHECKSUM` ([`quirks.md`][quirks-api])                                                                                          | not described                                                                 |

The pattern across the rows is that headers and chunk framing are declarative in
shape, while entropy payloads, escapes, stream continuation and checksum placement
are code that the framing must hand bytes to and get bytes back from. NIE, Wuffs'
own uncompressed format, is the counter-example: a 16-byte header of 4 magic bytes,
4 version-and-configuration bytes (a version byte, a fixed `b` and two flag bytes)
and two little-endian `uint32` dimensions, then raw pixels
([`nie-spec.md`][nie-spec]); a fixed-layout description covers it whole.

---

## Analysis

### 1. Pixel and memory model

A `wuffs_base__pixel_buffer` is a `pixel_config` (format, subsampling, width,
height) plus up to four planes, each a `table_u8` with pointer, width, height and
byte `stride` ([`image-public.h`][pixbuf]); see [plane][c-plane] and
[stride][c-stride]. An 8-bit planar sample is at `planes[p].ptr + (j * planes[p].stride) + i`, and
subsampling maps a pixel to a plane sample by a per-plane bias and denominator
([`pixel-subsampling.md`][pixsub]; [chroma subsampling][c-chroma]). The pixel format
is one `uint32_t` bit field: colour model and channel order, transparency, a
big-endian bit, a float bit, a palette bit, the plane count and four 4-bit channel
depths ([`pixel-formats.md`][pixfmt]). Channels are named "in memory order ...
regardless of endianness" ([source note][pixfmt-order]; [pixel format names][c-pixfmt]). Indexed images keep the
palette, always 256 × 4 bytes of non-premultiplied BGRA, in plane 3.

Two findings. First, the format note's worked example names `0x80000565` as BGR 565
(colour nibble 8 is BGR) and then calls the same value `0x40000565` twice (nibble 4
is YCbCr), so the hand-written prose has drifted from the bit layout it explains
([`pixel-formats.md`][pixfmt-565]); the code confirms
`WUFFS_BASE__PIXEL_FORMAT__BGR_565` is `0x80000565` ([`image-public.h`][bgr565]).
Second, the model is 2-D only: no N-D extent, no
tiles, and the pixel buffer carries "`// TODO: color spaces.`". Dimensions are
capped at `0xFF_FFFF` so that `width * height * bytes_per_pixel` cannot overflow an
`i64` ([`image-decoders.md`][image-decoders-limit]).

### 2. Genericity mechanism

There are no generics. Polymorphism is by interface: a struct declares `implements
base.image_decoder`, `base.io_transformer` or `base.hasher_u32`, and the C form
dispatches through a vtable recognised by a `vtable_name` string pointer
(`wuffs_base__image_decoder__vtable_name` in the snapshot). Pixel format variety is
a run-time value resolved once by the swizzler into a function pointer, and CPU
variety by `choose` (section 7). Code size is managed by preprocessor selection:
`WUFFS_CONFIG__MODULES` plus one `WUFFS_CONFIG__MODULE__X` per package, and an
allow-list of destination pixel formats (`WUFFS_CONFIG__DST_PIXEL_FORMAT__ENABLE_ALLOWLIST`)
that removes swizzler paths ([`pixconv-submodule-regular.c`][swizzler-prepare]).
The project's own measurements put `wuffs-base-pixconv` at 56,192 bytes and
`wuffs-std-png` at 54,760 bytes in a clang 11 shared build
([`binary-size.md`][binary-size]). Compared with the static genericity of
[Boost.GIL][gil] or [mir][mir], Wuffs keeps one compiled decoder and moves format
choice to run time.

### 3. Colour and metadata

Decoders do not manage colour. They report it. By default metadata is skipped;
`set_report_metadata(fourcc, true)` makes a decode call return
`"@metadata reported"`, after which `tell_me_more` describes it in one of three
flavours ([`metadata.md`][metadata]): parsed (small values such as gamma or the
eight chromaticity numbers), raw passthrough (a byte range of the input for the
caller to route to a separate parser) and raw transform (bytes the decoder must
process, for example decompress, before handing over). PNG maps `cICP` to a parsed
`'CICP'be` with the four bytes in `metadata_x`, `eXIf` to a passthrough range from
`position()` to `position() + chunk_length`, and `iCCP` to a zlib-inflated transform
([`decode_png.wuffs`][png-cicp], [`decode_png.wuffs`][png-iccp]); see
[CICP][c-cicp], [ICC profile][c-icc] and [image metadata][c-metadata]. Alpha state is
part of the pixel format: non-premultiplied, premultiplied or binary
([`pixel-formats.md`][pixfmt-alpha]; [straight and premultiplied alpha][c-alpha]).
There is no HDR transfer handling or gain map support. The swizzler does include
fixed YCbCr-to-RGB and CMYK/YCCK conversions
([`pixconv-submodule-ycck.c`][swizzler-ycck]); these do not apply an ICC profile.
The caller must perform profile-based colour management itself.

### 4. I/O and codec architecture

Wuffs is the catalog's clearest example of caller-driven
[incremental, suspendable decoding][c-incremental]: every public decode method is a
coroutine over caller-owned `io_buffer`s, so the same object serves a whole file
in memory, a pipe read in 4 KiB pieces, or an event loop that refills a buffer on
completion. In the [push and pull][c-pushpull] vocabulary the caller pushes bytes in
by filling the reader and the decoder pulls within what it is given; neither side
blocks. Compression decoders expose one method, `transform_io?(dst, src, workbuf)`,
and the I/O suspensions are how such decoders "decompress from arbitrarily long
inputs to arbitrarily long outputs with fixed sized buffers" ([`coroutines.md`][coroutines-io]); `example/zcat` does so with
static buffers under a `SECCOMP_MODE_STRICT` sandbox
([`memory-safety.md`][memsafety-api]).

The fast and slow paths split on suspension. Deflate's
`decode_huffman_fast64!` is an impure, non-suspending function that runs only while
`args.dst.length() >= 266` and `args.src.length() >= 8`, checking those bounds once
per iteration so the body needs no further checks; when either runs short it
returns and `decode_huffman_slow?`, a coroutine, handles the boundary
([`decode_huffman_fast64.wuffs`][fast64], [`decode_deflate.wuffs`][deflate-blocks]).
The PNG decoder inflates into a work buffer and then filters and swizzles rows
(one Adam7 pass at a time), rather than exposing a row-streaming API
([`decode_png.wuffs`][png-frame]). Whole-image inflation for non-interlaced PNG
is one reason [Tao's PNG article][tao-png] gives for its speed
(see [the entropy-codecs thread][p-entropy]).

Truncation is reported where it is detected. **Verified:** decoding
`hippopotamus.regular.truncated.png` with `closed` set at end of input returned
`"#deflate: truncated input"`, the inner decoder's status passed through PNG
unchanged.

### 5. Hostile input and safety

The [hostile-input][c-hostile] defence is primarily the language: bounds, overflow
and null checks proved at compile time, no allocation, no syscalls. Three limits on
that claim are written down in the repository:

- **Not everything in the C file is Wuffs.** The `base` package (I/O helpers, pixel
  conversion, string conversion) and the C++ `wuffs_aux` helpers are hand-written;
  the auxiliary-code note says "unlike code written in the Wuffs language, its
  memory-safety is not enforced by the Wuffs toolchain" ([`auxiliary-code.md`][aux]).
  The swizzler, which every image decode calls, is in that category and has its own
  fuzzer (`fuzz/c/std/pixel_swizzler_fuzzer.c`).
- **Uninitialised memory is opt-in risk.** `WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED`
  skips zeroing internal buffers; the compiler then refuses refinements on those
  fields, but reading uninitialised bytes "is not a bug class that the Wuffs compiler
  eliminates" ([`initialization.md`][init-partial]).
- **Termination and time are out of scope.** "Wuffs functions are not guaranteed to
  halt" ([`hermeticity.md`][hermeticity-halting]); there is no work budget, so a
  caller can stop between calls, but cannot enforce a time budget within a call
  through this API.

Logical impossibilities that the prover cannot see are written as explicit
`"#internal error: ..."` returns, and the fuzz harness turns those into crashes: "As
of November 2019, this has not yet found any memory-safety bugs in Wuffs"
([`fuzzing.md`][fuzzing]); `fuzzlib.c` calls `intentional_segfault()` on any
`"internal error:"` message and on a short read from a closed reader
([`fuzzlib.c`][fuzzlib]). Resource limits are structural: the 24-bit dimension cap,
exact work-buffer sizes, and fixed-size internal arrays (deflate history of
`0x8000 + 257` bytes, GIF's 4,096-byte compressed staging array).

**Verified** with the scratch program: flipping one bit of the IHDR CRC gave
`"#png: bad checksum"`, and the same file decoded with `QUIRK_IGNORE_CHECKSUM`;
flipping a bit of the final `IDAT` CRC gave `"#png: bad checksum"`; setting the IHDR
width to `0x0100_0000` gave `"#base: unsupported image dimension"`, reported from
`decode_ihdr` before the CRC comparison.

### 6. Allocation and ownership

Wuffs code cannot allocate. The caller allocates the decoder (size from
`sizeof__wuffs_png__decoder()`, 44,648 bytes **verified**, most of it fixed internal
arrays), the source and destination buffers, the pixel buffer and the work buffer.
Re-initialising resets an object, and "There are no destructor functions. Just free
the memory." ([`initialization.md`][init]). The C form adds `wuffs_foo__bar__alloc`
conveniences and `wuffs_aux::DecodeImage`, which allocate on the caller's side of
the boundary and assume synchronous I/O ([`auxiliary-code.md`][aux]). This is the
same split the [image-rs][image-rs] and [zune-image][zune] decoders approximate with
`decode_into`, but enforced: a Wuffs decoder has no way to retain a pointer to
caller memory between calls, because struct fields cannot hold pointers to
dynamically allocated memory ([`memory-safety.md`][memsafety-owner]).

### 7. CPU parallelism and SIMD

There is no threading: Wuffs "lacks the capability to create, destroy or otherwise
manage threads", and separate objects are safe on separate threads because there is
no global mutable state ([`memory-safety.md`][memsafety-threads]). SIMD is in the
language. A function marked `choose cpu_arch >= x86_sse42` (or `arm_neon`,
`x86_avx2`, `x86_bmi2`) can use typed vector values such as `base.x86_m128i`; a
`choosy` function names the default, and a `choose f = [a, b, c]` statement picks
the first variant the running CPU supports ([`common_crc32.wuffs`][crc32-choose],
[`common_up_x86_sse42.wuffs`][crc32-sse42], [`decode_png.wuffs`][png-choose]). In
the generated C, the choice is a `choosy_up` function pointer in the object, set
after a `wuffs_base__cpu_arch__have_x86_sse42()` check. SIMD paths exist for CRC-32
(SSE4.2, ARM CRC32), Adler-32 (SSE4.2, NEON), PNG filters (SSE4.2, NEON), deflate's
Huffman loop (BMI2), JPEG's IDCT (AVX2) and swizzler conversions (SSE4.2, AVX2 in
`pixconv-submodule-x86-avx2.c`). `WUFFS_CONFIG__AVOID_CPU_ARCH` removes all of them.

The project's own numbers (Intel i5-10210U, September 2022, against Debian's
libraries; [`benchmarks.md`][bench]) show what that buys: PNG decode at 1.55x to
3.16x libpng ([PNG table][bench-png]), zlib at 1.53x to 1.70x zlib-the-library and
roughly on par with libdeflate ([zlib table][bench-zlib]), deflate below zlib at
1 KiB (0.76x to 0.93x) and above it from 10 KiB ([deflate table][bench-deflate]),
and CRC-32 at 9.1x to 14.7x zlib but below libdeflate ([CRC-32 table][bench-crc32]).

### 8. GPU offload and interop

Not applicable: Wuffs has no GPU code and no notion of device memory. Two points
bear on Q6 all the same. Because the pixel buffer is caller-owned and described by
pointer and stride, a caller can in principle point it at mapped staging memory and
decode straight into it (an assessment; not demonstrated here). And `std/etc2`
decodes ETC1/ETC2 texture data to CPU pixels (its header comment describes both
the raw block format and the 16-byte PKM file header): the direction opposite to
upload, useful as an oracle for texture work
([`decode_etc2.wuffs`][etc2]).

### 9. Temporal, animation and containers

Animation is first-class in the image interface: `frame_config` carries the frame
rectangle, duration, disposal, blend mode and the frame's I/O position, and the
decoder reports `num_animation_loops`, `num_decoded_frames` and a
`frame_dirty_rect` ([`frame_config` fields][frame-config];
[`image-decoders.md`][image-decoders-api]). GIF and APNG support animation;
the WebP decoder tracks the `VP8X` chunk order including `ANIM`
and `ANMF` ([`decode_webp.wuffs`][webp-variant]), but skips their bodies
([chunk parser][webp-animation]), exposes only frame zero
([frame configuration][webp-frame]) and returns `0` from `num_animation_loops`
([counters][webp-counters]). It does not decode animated WebP frames at this revision.
Random access is cooperative: `restart_frame` plus an
I/O position, with the caller performing the seek. Containers are handled inside
each package (PNG chunks, RIFF for WebP, GIF blocks); there is no shared container
layer. `std/vp8` exists for lossy WebP, which "essentially wraps one VP8 key frame";
the WebP README notes "There's no Wuffs WebM package yet"
([`std/vp8/README.md`][vp8-readme], [`std/webp/README.md`][webp-readme]). NIA, the
animated sibling of NIE, is the project's own animation format
([`nie-spec.md`][nie-spec]); see [container and bitstream][c-container].

### 10. Testing and conformance

Each package has a C test file under `test/c/std/` that runs as unit tests or, with
`-bench`, as benchmarks; "mimic" tests compare Wuffs' output byte-for-byte with
another library's on the same input, which is also how quirks are justified
([`benchmarks.md`][bench], [`quirks.md`][quirks-mimic]). The mimic libraries live
under `test/c/mimiclib/`, one file per family (PNG, GIF, deflate with gzip and zlib,
JPEG, WebP, LZMA, bzip2, stb and others). A corpus-wide oracle covers decoded output:
`script/print-nia-checksums.sh` runs `example/convert-to-nia` over every file in
`test/data` and prints the CRC-32 of each decodable file's NIA output, and
`build-all.sh` diffs that against the committed `test/nia-checksums-of-data.txt`
(207 lines) ([`print-nia-checksums.sh`][nia-script], [`build-all.sh`][build-all]).
Fuzzing has run on OSS-Fuzz since February 2018 ([`fuzzing.md`][fuzzing]), with
per-format fuzzers in `fuzz/c/std/` and seed corpora listed in `seed_corpora.txt`.
The compile-time checker is itself part of conformance: it fails the build, not a
test. The [hostile-input thread][p-hostile] places this beside verified parsers and
differential testing.

---

## Lessons for Sparkles

- **Q4.** The three-phase API (config, caller allocates, frame) with a declared
  `workbuf_len` range maps directly onto Sparkles' standing rules: a decoder struct
  whose methods are `@safe nothrow @nogc`, taking caller slices
  (`scope ubyte[]` under dip1000) and never storing them, with sizes as `size_t`.
  It is the shape `font.png` already has and `ui.png` lacks
  ([existing-code baseline][bl-existing], G6 and G7). What does not transfer as-is
  is the four-category status model: Wuffs separates ok, note, suspension and error, while
  `Expected` has two arms. The wired baseline's G3 and its decision 3 record that a
  suspension status must coexist with `Expected` ([wired baseline][bl-wired]); Wuffs
  is evidence that suspension should be a value, not an error kind.
- **Q4.** The [description table](#what-a-binary-description-format-would-have-to-express)
  is the requirement list for the later wired experiment. Of its thirteen rows,
  fixed integers, field predicates and self-sized chunk sequences have drafted
  counterparts in Flat; bit streams, escapes, stream continuation across chunks,
  checksums over payload ranges, suspension and 64-bit positions do not
  ([wired baseline][bl-wired], G2 to G6). Wuffs itself does not describe these
  declaratively: it writes them as code over a reader with `mark`, `since` and
  `io_limit`. A description format that framed chunks and handed scoped readers to
  codec code would cover what Wuffs keeps declarative-shaped; one that tried to
  describe the entropy layer would be describing a program.
- **Q4.** Wuffs' resumption is a generated `switch` with per-coroutine scratch in the
  receiver. D has no stackless coroutines; the options on the branch are a hand-
  or `mixin`-generated state machine of the same shape, or fibers, which the
  [event-horizon baseline][bl-eh] (G6) says cannot migrate between threads. The
  generated shape needs nothing from a runtime, so it is the one compatible with
  `--better-c`, `--wasm` and Android builds; that compatibility is an inference
  from the generated C, not a D measurement.
- **Q4, Q8.** The fast-path/slow-path split (check "8 bytes in, 266 bytes out" once,
  then run an unchecked inner loop; fall back to a suspending path at boundaries)
  is the D answer to "bounds checks cost": slice once per iteration so the
  compiler, or a single reviewed `@trusted` lambda, elides per-byte checks. Whether
  LDC removes the checks in a `checked` build is a measurement Sparkles has not
  made ([shaders and SIMD baseline][bl-shaders]).
- **Q8.** Three testing devices transfer without the language: byte-exact "mimic"
  tests against reference libraries; a committed checksum of every decoded file in
  the corpus, diffed by the build; and fuzzers that crash on any "impossible" status.
  The last maps onto D `assert(0)` in a fuzz build. The existing-code baseline's G11
  records that Sparkles' oracles are single-purpose ([existing-code
  baseline][bl-existing]).
- **Q8.** Checksum policy is a quirk: critical PNG chunks are verified and
  ancillary CRCs are skipped. Wuffs' source compares this with libpng's
  warn-and-discard policy for bad ancillary CRCs ([PNG][png-chunks]). Both Sparkles PNG decoders skip all chunk
  CRCs ([existing-code baseline][bl-existing], G1); Wuffs shows verification costs
  little on one upstream benchmark (837 versus 871 MB/s,
  verify against ignore, clang 11; [PNG table][bench-png]). That result does not
  establish the cost for every image or CPU.
- **Q1.** The pixel buffer (format word, up to four planes, per-plane stride, a
  subsampling description) is the minimal 2-D model that holds both RGBA and 4:2:0;
  it is not N-D. The drift found in `pixel-formats.md` is a small instance of the
  hazard Sparkles' rule "enum names are wired data" addresses: generate names and
  documentation from the bit layout, do not hand-maintain both.
- **Q5.** "Report, do not convert" is a complete minimum: CICP as four bytes, gamma
  and chromaticities parsed, ICC and EXIF as ranges or inflated bytes, alpha state
  in the format. It leaves colour management to a separate layer, which is the
  question Q5 asks.
- **Q3, Q7.** `choose` is per-function CPU dispatch that stores the selected
  function pointer in the object for subsequent calls. CRC-32 selects when its
  state is zero ([`common_crc32.wuffs`][crc32-choose]). The [shaders and SIMD baseline][bl-shaders] (G5) records that
  Sparkles repeats dispatch by hand; Wuffs is evidence for one mechanism that every
  kernel names, with a portable default always present.
- **Q6.** Caller-owned, strided pixel memory could let a decoder write directly into
  CPU-writable GPU staging memory, subject to its format, stride and synchronization
  requirements. This is an ownership-based assessment, not a demonstrated GPU path.
  Whether `sparkles:vulkan`'s one upload path can accept it is in the
  [Vulkan baseline][bl-vk].
- **Q9.** The release is one C file with per-package macros, a `base` of shared
  types and conversion, and one package per codec. That is evidence for a small
  shared core (buffers, statuses, pixel format, swizzler) under per-format codecs.
  It also shows where unproved code concentrates: in the shared conversion core.
  **Verified:** a full PNG decode from D through ImportC header mode (LDC 1.43.0,
  implementation built by GCC 16.2.0 with SIMD) matched the C probe's `153761e2`
  pixel hash and 44,648-byte decoder size. The opaque decoder was allocated with
  the C size function. The D header wrapper undefines `__SIZEOF_INT128__` and
  `__SIZEOF_LONG__` and defines `WUFFS_CONFIG__AVOID_CPU_ARCH`;
  `NIX_HARDENING_ENABLE` was empty. The same decode passed with the scalar
  implementation compiled through ImportC using those workarounds and
  `WUFFS_IMPLEMENTATION`. This establishes neither SIMD implementation compilation
  by ImportC nor ABI compatibility for every codec. See [ImportC C libraries][importc].

---

## Strengths

- Bounds, overflow and null safety proved at compile time, with no run-time checks
  in the shipped inner loops.
- Hermetic by construction: no allocation, I/O, globals, callbacks or threads, so
  the attack surface is the input bytes alone.
- Every decode is suspendable over caller buffers, with a small, uniform status
  vocabulary and sticky errors.
- One image interface for stills and animation, with implicit calls, frame counting
  without decompression and random access by I/O position.
- Declared memory needs (`workbuf_len` ranges, `sizeof` functions) before any pixel
  is decoded.
- Ships as one C99 file with per-package selection; usable without the Go toolchain.
- Fast on the project's own benchmarks, and backed by mimic tests, a corpus
  checksum oracle and OSS-Fuzz since 2018.

## Weaknesses

- Writing Wuffs is slow; the README says so, and the toolchain's documentation has
  open `TODO`s about when facts are removed and what is proved automatically.
- The pixel swizzler, string conversion and `wuffs_aux` are hand-written C or C++
  outside the proof.
- No encoders, no profile-based colour management or HDR transfer handling, and no N-D or tiled images.
- Termination and work are unbounded; a time or work budget is the caller's
  problem.
- The [roadmap][roadmap] still lists JPEG and WebP decoding as future work,
  although their decoders exist at this revision: that document lags the code.
- Consuming the C file from another language's C importer needs workarounds
  (verified for D ImportC above).

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                               | Trade-off                                                                          |
| -------------------------------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Compile-time proof instead of run-time checks                  | Safety without per-access cost in hot loops                             | Programmers write facts, invariants and axiom citations; slower to author          |
| Proof checker with named axioms, no SMT solver                 | Fast, reproducible compilation                                          | More explicit annotation; the checker proves only what it is told                  |
| Hermetic language: no allocation, syscalls, callbacks, threads | Trivial safety against leaks, use-after-free and ambient authority      | Every API is multi-step; convenience layers live outside the proof                 |
| Coroutines with I/O suspensions over caller `io_buffer`s       | Arbitrary input and output sizes with fixed memory; works sync or async | State machines in every receiver; facts about `this` lost at each suspension point |
| Status as a static string with a category byte                 | Pointer comparison, no allocation, readable in debugging                | No structured error context (offset, field) beyond the message                     |
| Config, then caller-allocated pixel and work buffers           | The caller can refuse oversized images before allocating                | Two or three calls per frame; work buffer may equal the whole filtered image       |
| 24-bit dimension cap                                           | Overflow-free arithmetic on sizes everywhere                            | Images wider or taller than 16,777,215 pixels are refused                          |
| Quirks as numbered `set_quirk` keys                            | Match other decoders' behaviour on malformed input; mimic tests         | Behaviour depends on configuration that must be recorded with results              |
| Pixel conversion in hand-written C                             | Function pointers and SIMD that the language lacked                     | The most widely called conversion code is outside the proof                        |
| One generated C file with module macros                        | stb-style integration; no Wuffs toolchain needed by users               | A 3.7 MB source file; importers of C headers meet compiler-specific constructs     |

---

## Sources

- [google/wuffs][repo], read at `4be865da258c4b5e6d3e716fd4f36be016496a46`:
  [`README.md`][readme-safety], [language][lang-doc], [library][lib-doc],
  [notes][doc-note], [image API][image-decoders-api], [call sequence][call-seq],
  [compression API][compression-decoders], [metadata][metadata], [benchmarks][bench],
  [binary size][binary-size], [NIE specification][nie-spec], [axioms][axioms].
- Standard library: [PNG][png-dic], [zlib][zlib-transform], [deflate][deflate-blocks],
  [fast Huffman loop][fast64], [CRC-32][crc32-choose], [JPEG][jpeg-fill],
  [GIF][gif-blocks], [WebP][webp-variant], [ETC2][etc2].
- C base and release: [base README][cgen-base-readme], [coroutine macros][coro-macros],
  [I/O][io-meta], [pixels][pixbuf], [swizzler][swizzler-prepare],
  [release README][release-readme], [snapshot][snapshot].
- Tests and fuzzing: [`fuzz/c/fuzzlib/fuzzlib.c`][fuzzlib], [`build-all.sh`][build-all].
- Background: [Tao's PNG article][tao-png] (2021), the [entropy-codecs thread][p-entropy],
  the [hostile-input thread][p-hostile] and [Sans I/O][sans-io].
- Sparkles baselines: [wired][bl-wired], [existing code][bl-existing], [SIMD][bl-shaders], [event-horizon][bl-eh], [Vulkan][bl-vk].

<!-- References -->

[repo]: https://github.com/google/wuffs/tree/4be865da258c4b5e6d3e716fd4f36be016496a46
[doc]: https://github.com/google/wuffs/tree/4be865da258c4b5e6d3e716fd4f36be016496a46/doc
[doc-note]: https://github.com/google/wuffs/tree/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note
[doc-std]: https://github.com/google/wuffs/tree/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/std
[changelog]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/changelog.md#L1-L10
[release-readme]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/release/c/README.md#L17-L23
[readme-safety]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/README.md#L38-L52
[readme-hermetic]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/README.md#L55-L69
[readme-example]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/README.md#L84-L113
[readme-status]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/README.md#L224-L242
[lang-doc]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/wuffs-the-language.md#L8-L16
[lib-doc]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/wuffs-the-library.md#L21-L27
[hermeticity]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/hermeticity.md#L55-L70
[hermeticity-halting]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/hermeticity.md#L82-L88
[memsafety-owner]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/memory-safety.md#L10-L16
[memsafety-api]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/memory-safety.md#L41-L64
[memsafety-threads]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/memory-safety.md#L72-L77
[assertions-axioms]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/assertions.md#L43-L49
[axioms]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/lang/check/axioms.md#L1-L11
[bounds]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/bounds-checking.md#L1-L23
[facts]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/facts.md#L55-L95
[facts-loops]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/facts.md#L118-L147
[interval]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/interval-arithmetic.md#L57-L67
[effects]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/effects.md#L1-L23
[coroutines]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/coroutines.md#L1-L50
[coroutines-io]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/coroutines.md#L23-L50
[statuses]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/statuses.md#L1-L65
[coro-macros]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/internal/cgen/base/fundamental-private.h#L26-L46
[snapshot]: https://raw.githubusercontent.com/google/wuffs/4be865da258c4b5e6d3e716fd4f36be016496a46/release/c/wuffs-unsupported-snapshot.c
[snapshot-version]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/release/c/wuffs-unsupported-snapshot.c#L73-L81
[zlib-generated]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/release/c/wuffs-unsupported-snapshot.c#L69968-L70010
[io-meta]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/internal/cgen/base/io-public.h#L17-L46
[io-buffers]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/io-input-output.md#L17-L35
[io-position]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/io-input-output.md#L63-L73
[io-closed]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/io-input-output.md#L76-L86
[io-undo]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/io-input-output.md#L89-L100
[tokens]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/tokens.md#L1-L45
[image-decoders-limit]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/std/image-decoders.md#L12-L17
[image-decoders-api]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/std/image-decoders.md#L105-L121
[image-decoders-impls]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/std/image-decoders.md#L124-L139
[call-seq]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/std/image-decoders-call-sequence.md#L1-L118
[compression-decoders]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/std/compression-decoders.md#L1-L44
[metadata]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/std/metadata.md#L1-L57
[quirks-mimic]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/quirks.md#L24-L28
[quirks-api]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/quirks.md#L31-L53
[quirks-list]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/quirks.md#L56-L65
[init]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/initialization.md#L1-L30
[init-partial]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/initialization.md#L48-L69
[aux]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/auxiliary-code.md#L11-L46
[fuzzing]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/fuzzing.md#L1-L13
[fuzzlib]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/fuzz/c/fuzzlib/fuzzlib.c#L95-L110
[build-all]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/build-all.sh#L95-L103
[pixfmt]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-formats.md#L1-L40
[pixfmt-order]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-formats.md#L59-L64
[bgr565]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/internal/cgen/base/image-public.h#L606-L608
[pixfmt-alpha]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-formats.md#L66-L75
[pixfmt-565]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-formats.md#L42-L110
[pixsub]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/pixel-subsampling.md#L3-L30
[pixbuf]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/internal/cgen/base/image-public.h#L1508-L1516
[frame-config]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/internal/cgen/base/image-public.h#L1274-L1306
[swizzler-prepare]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/internal/cgen/base/pixconv-submodule-regular.c#L8181-L8374
[swizzler-ycck]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/internal/cgen/base/pixconv-submodule-ycck.c#L118-L265
[cgen-base-readme]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/internal/cgen/base/README.md#L17-L25
[binary-size]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/binary-size.md#L1-L29
[nie-spec]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/spec/nie-spec.md#L9-L39
[png-dic]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L182-L230
[png-chunks]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L232-L303
[png-ihdr]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L337-L403
[png-choose]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L499-L523
[png-cicp]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L708-L730
[png-iccp]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L823-L854
[png-pass]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L1292-L1394
[png-workbuf]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L1757-L1761
[png-frame]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L1156-L1290
[zlib-transform]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/zlib/decode_zlib.wuffs#L106-L179
[deflate-bits]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/deflate/decode_deflate.wuffs#L67-L70
[deflate-blocks]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/deflate/decode_deflate.wuffs#L251-L335
[fast64]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/deflate/decode_huffman_fast64.wuffs#L13-L83
[crc32-choose]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/crc32/common_crc32.wuffs#L27-L43
[crc32-sse42]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/crc32/common_up_x86_sse42.wuffs#L11-L13
[jpeg-bitstream]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/jpeg/decode_jpeg.wuffs#L276-L282
[jpeg-fill]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/jpeg/decode_jpeg.wuffs#L1723-L1785
[jpeg-workbuf]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/jpeg/decode_jpeg.wuffs#L2269-L2279
[gif-blocks]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/gif/decode_gif.wuffs#L935-L1036
[webp-variant]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/webp/decode_webp.wuffs#L48-L59
[webp-frame]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/webp/decode_webp.wuffs#L439-L470
[webp-animation]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/webp/decode_webp.wuffs#L513-L570
[webp-counters]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/webp/decode_webp.wuffs#L606-L627
[roadmap]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/roadmap.md#L1-L17
[vp8-readme]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/vp8/README.md#L1-L8
[webp-readme]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/webp/README.md#L1-L15
[nia-script]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/script/print-nia-checksums.sh#L14-L66
[etc2]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/etc2/decode_etc2.wuffs#L12-L40
[bench]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/benchmarks.md#L1-L36
[bench-png]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/benchmarks.md#L385-L418
[bench-zlib]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/benchmarks.md#L456-L476
[bench-deflate]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/benchmarks.md#L157-L190
[bench-crc32]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/benchmarks.md#L138-L154
[tao-png]: https://nigeltao.github.io/blog/2021/fastest-safest-png-decoder.html
[sans-io]: https://sans-io.readthedocs.io/
[c-plane]: ./concepts.md#plane
[c-stride]: ./concepts.md#stride
[c-chroma]: ./concepts.md#chroma-subsampling
[c-pixfmt]: ./concepts.md#pixel-format-names-and-byte-order
[c-cicp]: ./concepts.md#cicp
[c-icc]: ./concepts.md#icc-profile
[c-metadata]: ./concepts.md#image-metadata
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-hostile]: ./concepts.md#hostile-input
[c-container]: ./concepts.md#container-and-bitstream
[skia]: ./skia.md
[gil]: ./boost-gil.md
[mir]: ./mir-algorithm/index.md
[image-rs]: ./image-rs.md
[zune]: ./zune-image.md
[bl-wired]: ./baseline/wired.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-eh]: ./baseline/event-horizon.md
[bl-vk]: ./baseline/vulkan.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-entropy]: ./papers/entropy-codecs.md
[importc]: ../../guidelines/importc-c-libraries.md
