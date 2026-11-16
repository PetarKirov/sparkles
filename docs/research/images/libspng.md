# libspng (C)

A single-file C99 PNG reader and writer that replaces libpng's callback-and-`setjmp` API with one opaque context, a pull-model byte source and integer error codes; its memory limits require caller configuration, and its decoder is progressive by rows but not suspendable.

| Field         | Value                                                                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C99 ([`meson.build`][meson]), one translation unit [`spng/spng.c`][spng-c] (6,980 lines) and one header [`spng/spng.h`][spng-h] (537 lines)                   |
| License       | BSD-2-Clause; the SIMD filter code derived from libpng is under the PNG Reference Library License version 2 ([`spng.c`][simd-license], [`README.md`][readme]) |
| Repository    | [randy408/libspng][repo]                                                                                                                                      |
| Revision read | `46c81dc2b3747fa43aac33704c890a468f195d6e` (`master` merge, August 31, 2026; header and Meson version `0.7.4`, the release of May 8, 2023)                    |
| Documentation | [libspng.org/docs][site-docs] · in-tree [`docs/`][docs-dir] ([`decode.md`][decode-md], [`context.md`][context-md], [`chunk.md`][chunk-md])                    |
| Category      | Formats: PNG 1.2 codec with a context API and zlib or miniz as the inflate backend                                                                            |
| Tier          | A                                                                                                                                                             |
| Last reviewed | November 15, 2026                                                                                                                                             |

> [!NOTE]
> The clone is shallow, so the history before the pinned merge was read through the GitHub
> API, as were the release notes and the commits that landed upstream after the pin (November 10
> to 13, 2026), which this page cites where they fix something the pinned code gets wrong. Claims
> marked **verified** come from two C probes compiled with GCC 14.3.0 against the pinned
> `spng.c` and zlib 1.3.2 under AddressSanitizer and UndefinedBehaviorSanitizer, in a scratch
> directory under `/tmp`. The verifier reran both probes on November 15, 2026 with GCC 16.2.0,
> zlib 1.3.2 and the same sanitizers, against freshly extracted pinned source in
> `/tmp/libspng-verify-epypAA`; the reported results matched. An additional probe checked the
> discarded text chunk and a sub-8-KiB chunk limit. A second verifier wrote an independent probe
> (same compiler, zlib and sanitizers) that reproduced every verified result and also confirmed
> the critical-CRC skip described in section 5. These are scratch probes, not CI examples.
> No performance number in this page was measured; the project's own
> benchmark chart carries no methodology, so none is repeated here.

---

## Overview

### What it solves

libpng is the reference PNG implementation, and its API is old: errors arrive through a
`setjmp`/`longjmp` handler, transformations are switched on one call at a time
(`png_set_expand`, `png_set_strip_16`, and so on), and the image header lives in a separate info
structure. libspng covers every PNG 1.2 colour type and bit depth,
Adam7 and the standard PNG 1.2 ancillary chunks, adds `eXIf` and an encoder, and offers a context, a target
pixel format and return codes. The README states the scope in its first lines ([`README.md`][readme-intro]):

> _"lib**spng** (**s**imple **png**) is a C library for reading and writing Portable Network Graphics (PNG)
> format files with a focus on security and ease of use."_

and the motivation under its Motivation heading ([`README.md`][readme-motivation]):

> _"The goal is to provide a fast PNG library with a simpler API than libpng,
> it outperforms the reference implementation in common use cases."_

The common case is a four-call decode: create a context, set the input, ask for the output size
in a chosen format, decode into a caller buffer. Every PNG colour type and depth converts to
`SPNG_FMT_RGBA8`, `SPNG_FMT_RGBA16` or `SPNG_FMT_RGB8`; `SPNG_FMT_PNG` and `SPNG_FMT_RAW`
return the samples untouched (host-endian and big-endian respectively) ([`decode.md`][decode-formats]).

### Design philosophy

Three commitments recur in the source and the documentation.

1. **One opaque context holds everything.** `spng_ctx` is a single heap object: the input
   cursor, every parsed chunk, the zlib stream, the scanline buffers and the decode state
   machine ([`spng.c`][ctx-struct]). The migration guide says so directly: _"The context handle
   `spng_ctx` is an opaque datatype that holds all information, there is no separate info
   struct."_ ([`migrate-libpng.md`][migrate]).
2. **Errors are values, and a critical one poisons the context.** Status-returning functions return `0` or a
   `spng_errno` value (the enum has 88 enumerators, [`spng.h`][errno]). A critical error sets the state to
   `SPNG_STATE_INVALID` through `decode_err` ([`spng.c`][decode-err]), and _"most functions check
   for a valid context state and return `SPNG_EBADSTATE` for subsequent calls to prevent
   undefined behavior"_ ([`decode.md`][decode-errors]). The row entry points omit that state
   check at the pin, as the probes below demonstrate.
3. **Lenient by default, for compatibility with files in the wild.** _"The default behavior is
   meant to emulate libpng for compatibility reasons with existing images in the wild, most
   non-critical errors are ignored. Configuring decoder strictness is currently limited to
   checksums."_ ([`decode.md`][decode-errors]). Many malformed ancillary chunks are discarded;
   limit errors remain fatal. A bad CRC on an ancillary chunk is discarded by default since 0.6.2
   ([`spng.h`][crc-enum]).

The README's security claims are process claims: the code follows the CERT C coding standard,
_"All integer arithmetic is checked for overflow and all error conditions are handled
gracefully"_, and it is fuzzed on OSS-Fuzz and scanned by Clang Static Analyzer, Coverity and
PVS-Studio ([`README.md`][readme-security]). Where this page tests those claims, it says so.

---

## How it works

### The context and its state machine

A decoder context moves through a linear state machine ([`spng.c`][state-enum]):

```c
// spng/spng.c (abridged)
enum spng_state
{
    SPNG_STATE_INVALID = 0,
    SPNG_STATE_INIT = 1, /* No PNG buffer/stream is set */
    SPNG_STATE_INPUT, /* Decoder input PNG was set */
    SPNG_STATE_IHDR, /* IHDR was read/written */
    SPNG_STATE_FIRST_IDAT,  /* Encoded up to / reached first IDAT */
    SPNG_STATE_DECODE_INIT, /* Decoder is ready for progressive reads */
    SPNG_STATE_EOI, /* Reached the last scanline/row */
    SPNG_STATE_LAST_IDAT, /* Reached last IDAT, set at end of decode_image() */
    SPNG_STATE_AFTER_IDAT, /*  */
    SPNG_STATE_IEND, /* Reached IEND */
};
```

Chunk getters run `read_chunks` first, usually through the `SPNG_GET_CHUNK_BOILERPLATE` macro
([`spng.c`][boilerplate]), so metadata is parsed lazily: calling `spng_get_text` before decoding
reads every chunk up to the first `IDAT`, and calling it after decoding reads on to `IEND`.
`spng_get_ihdr` is the exception: it reads only the header
([`chunk.md`][chunk-semantics]). `spng_ctx_new2` takes a `struct spng_alloc` of four function
pointers (`malloc_fn`, `realloc_fn`, `calloc_fn`, `free_fn`), and the same allocator is passed
to zlib through `spng__zalloc` ([`spng.c`][ctx-new2], [`context.md`][context-new2]).

### Input: buffer, stream or file

Three setters choose the source, once per context ([`spng.c`][set-input]):

- `spng_set_png_buffer` keeps a pointer to the caller's bytes. Its read function,
  `buffer_read_fn`, copies nothing: it advances `ctx->data` and decrements `bytes_left`, so
  every chunk is parsed in place ([`spng.c`][buffer-read]).
- `spng_set_png_stream` takes a `spng_rw_fn` and a user pointer and allocates an 8 KiB
  `stream_buf` (`SPNG_READ_SIZE`, marked _"Not build options, edit at your own risk!"_,
  [`spng.c`][read-size]). The callback contract is blocking: _"A read callback function should
  copy `length` bytes to `dest` and return 0 or `SPNG_IO_EOF`/`SPNG_IO_ERROR` on error"_
  ([`context.md`][context-rw]).
- `spng_set_png_file` wraps `fread` and `fwrite` in the same callback type.

The API is therefore [pull][c-pushpull]: the decoder asks for exactly `length` bytes and the
source either supplies them or fails. There is no "need more input" return, so a source that does
not have the bytes yet must block inside the callback. The decoder cannot be suspended and
resumed when data arrives (see [suspendable decoding][c-suspend]).

### Chunk parsing and the undo log

`read_header` reads the previous chunk's CRC and the next chunk's length and type in one step
([`spng.c`][read-header]); `read_chunk_bytes` feeds every byte it reads to `crc32`
([`spng.c`][read-chunk-bytes]). Because the CRC trails the data, a chunk is parsed and stored
before its CRC is known. `read_non_idat_chunks` handles this with an undo log: each
arbitrary-length chunk handler sets `ctx->undo` (`text_undo`, `splt_undo`, `chunk_undo`), and
when the next `read_header` sets `ctx->discard` after a bad ancillary CRC, the loop calls the undo function and
restores the `stored` bitfield from `prev_stored` ([`spng.c`][non-idat-loop]).

Chunks with a fixed small payload (`PLTE`, `cHRM`, `gAMA`, `sBIT`, `sRGB`, `bKGD`, `tRNS`,
`hIST`, `pHYs`, `tIME`, `oFFs`) are recognised by `is_small_chunk` and read with at most 768
bytes, the size of a 256-entry `PLTE` ([`spng.c`][small-chunk]); they are stored in fixed fields
of the context and allocate nothing. `eXIf`, `iCCP`, `tEXt`, `zTXt`, `iTXt`, `sPLT` and unknown
chunks allocate and are charged to the chunk cache.

When a chunk fails validation, `read_chunks` consults a list of 43 recoverable error codes: if the
chunk is ancillary and the context is not strict, the rest of the chunk is skipped, the undo
function runs, and parsing continues ([`spng.c`][read-chunks-discard]):

```c
// spng/spng.c, read_chunks()
                case SPNG_EZLIB:
                {
                    if(!ctx->strict && !is_critical_chunk(&ctx->current_chunk))
                    {
                        ret = discard_chunk_bytes(ctx, ctx->cur_chunk_bytes_left);
                        if(ret) return decode_err(ctx, ret);

                        if(ctx->undo) ctx->undo(ctx);
```

`ctx->strict` has no setter at the pinned revision: a search of `spng.c` finds it read four times
and never assigned, so strict mode is unreachable through the public API.

### Inflate

Metadata streams (`iCCP`, `zTXt`, compressed `iTXt`) go through `spng__inflate_stream`, which
starts with an 8 KiB buffer and doubles it until the stream ends, refusing to grow past the
smaller of the chunk size limit and the remaining cache budget. The initial buffer and the final
size are not checked against that bound, so limits below 8 KiB can be bypassed
([`spng.c`][inflate-stream], [verified below](#_5-hostile-input-and-safety)):

```c
// spng/spng.c, spng__inflate_stream()
        if(!stream->avail_out) /* Resize buffer */
        {
            /* overflow or reached chunk/cache limit */
            if( (2 > SIZE_MAX / size) || (size > max / 2) )
            {
                ret = SPNG_ECHUNK_LIMITS;
                goto err;
            }
```

Image data is inflated directly into the scanline buffer by `read_scanline_bytes`, which asks
`read_idat_bytes` for more input whenever zlib returns `Z_BUF_ERROR`, stepping over `IDAT`
boundaries ([`spng.c`][scanline-bytes]). With buffer input, `read_idat_bytes` consumes a whole
`IDAT` chunk per call; with stream input, at most 8 KiB. Before inflating, `spng_decode_image`
peeks at the zlib header's `FLEVEL` bits and exposes them as an estimate through
`SPNG_IMG_COMPRESSION_LEVEL` ([`spng.c`][flevel]).

### Scanlines, filters and the one-byte offset

Each row is read together with the _next_ row's filter byte, so that the pixel data starts at
offset zero of the buffer ([`spng.c`][first-filter]):

```c
// spng/spng.c, spng_decode_image()
    /* Read the first filter byte, offsetting all reads by 1 byte.
    The scanlines will be aligned with the start of the array with
    the next scanline's filter byte at the end,
    the last scanline will end up being 1 byte "shorter". */
    ret = read_scanline_bytes(ctx, &ri->filter, 1);
```

`read_scanline` then validates that filter byte (greater than 4 is `SPNG_EFILTER`), byte-swaps
16-bit samples to host order _before_ defiltering, and calls `defilter_scanline`
([`spng.c`][read-scanline]). Swapping first is sound because every filter works bytewise at a
distance of `bytes_per_pixel`, which is even for 16-bit images, so the byte permutation commutes
with the filter arithmetic. Only two rows are live (`scanline`, `prev_scanline`, swapped after
each row), plus a third, `row`, for interlaced images ([`decode.md`][decode-memory]).

`spng_decode_scanline` converts one defiltered scanline to the output format using branches on
colour type and depth, with whole-row fast paths for some combinations ([`spng.c`][conversion-loop]), then applies `trns_row`, `scale_row` (for
`sBIT`) and `gamma_correct_row` as whole-row passes ([`spng.c`][decode-scanline-tail]).
`spng_decode_row` adds Adam7 scatter: for passes 0 to 5 it decodes into `ctx->row` and copies
each pixel to `adam7_x_start[pass] + k * adam7_x_delta[pass]` in the caller's row
([`spng.c`][decode-row]).

### Progressive decoding

With `SPNG_DECODE_PROGRESSIVE`, `spng_decode_image` initialises the decoder and returns; the
caller then pulls rows. For interlaced images rows arrive out of order, so the documented loop
asks for the destination first ([`decode.md`][decode-progressive]):

```c
// docs/decode.md
do
{
    error = spng_get_row_info(ctx, &row_info);
    if(error) break;

    void *row = image + image_width * row_info.row_num;

    error = spng_decode_row(ctx, row, len);
}
while(!error)

if(error == SPNG_EOI) /* success */
```

`spng_row_info` carries `scanline_idx`, `row_num` (the deinterlaced row), `pass` and `filter`
([`spng.h`][row-info]). This is [progressive][c-suspend] in the row sense only: the caller
controls when each row is produced, but each call still blocks in the read callback until its
bytes exist.

---

## Analysis

### 1. Pixel and memory model

There is no image type. The output is a caller-owned byte buffer whose size
`spng_decoded_image_size` computes as row bytes times height, with overflow checks at
each multiplication; `SPNG_FMT_PNG` and `SPNG_FMT_RAW` retain packed sub-byte samples
([`spng.c`][image-size]). Rows are tightly packed, with no [stride][c-stride]
parameter and no alignment option. Progressive decoding hands out one row at a time, so a
caller can place rows anywhere, which is the only way to get a strided or tiled destination.
The pixel vocabulary is the eight `spng_format` values; _"Channels are always in byte-order"_
and 16-bit outputs are host-endian except `SPNG_FMT_RAW` ([`spng.h`][fmt-enum]). Alpha is
_"always straight alpha, premultiplied alpha is not supported"_ ([`decode.md`][decode-formats])
(see [straight and premultiplied alpha][c-alpha]). `SPNG_FMT_G8`, `GA8` and `GA16` are partial:
`check_decode_fmt` accepts `G8`/`GA8` only for 1-, 2-, 4- or 8-bit greyscale input, and
`GA16` only for 16-bit greyscale input; greyscale-alpha input is rejected ([`spng.c`][check-fmt]).

### 2. Genericity mechanism

None in the language sense. Format conversion is a run-time switch inside one loop
(`spng_decode_scanline`), with flags precomputed once per image into `struct decode_flags`
(`same_layout`, `unpack`, `do_scaling`, `apply_trns`, `apply_gamma`, `indexed`, `interlaced`)
([`spng.c`][decode-flags]). A `zerocopy` flag that would let a same-layout, non-interlaced
decode skip the copy exists but its assignment is commented out ([`spng.c`][zerocopy]). The
choice of output format is a value, not a type. The conversion loop contains branches on
image-invariant values, as well as whole-row fast paths ([`spng.c`][conversion-loop]). Whether
the compiler hoists or specialises the remaining branches was not checked. A D implementation
could express format specialisation with compile-time parameters; its benefit needs measurement.

### 3. Colour and metadata

libspng parses colour chunks and exposes them; it applies almost none of them.

- **Gamma.** `SPNG_DECODE_GAMMA` builds a lookup table from `gAMA` with a fixed screen gamma of
  2.2 (`float screen_gamma = 2.2f`) and `pow` on `float` operands (upstream switched to `powf` after the pin); the table is 256 entries for 8-bit
  outputs and a 128 KiB allocation for 16-bit ([`spng.c`][gamma-lut], [`decode.md`][decode-memory]).
  It is not implemented for `SPNG_FMT_PNG`, `G8`, `GA8` or `GA16` ([`README.md`][readme-known]),
  and it ignores `sRGB`, `cHRM` and `iCCP` when deciding whether to apply.
- **ICC.** `iCCP` is inflated and returned as bytes; _"ICC profiles are not validated"_
  ([`chunk.md`][chunk-iccp]). See [ICC profile][c-icc].
- **CICP, HDR and gain maps.** Absent. The `spng_chunk_bitfield` has 17 fields
  ([`spng.c`][chunk-bitfield]) and none is `cICP`, `mDCV` or `cLLI`, which the third edition of the
  PNG specification added ([W3C PNG third edition][png3]). A `cICP` chunk is treated as unknown:
  discarded, or kept as raw bytes with `SPNG_KEEP_UNKNOWN_CHUNKS`. No [CICP][c-cicp] or
  [gain-map][c-gainmap] support exists.
- **EXIF and XMP.** `eXIf` is supported and checked only for a `II*\0` or `MM\0*` byte-order
  mark (`check_exif`, [`spng.c`][check-exif]); the TIFF structure is not parsed. XMP travels in
  an `iTXt` chunk with the keyword `XML:com.adobe.xmp` and is returned as ordinary text. Text
  is validated as Latin-1 only in strict mode, which is unreachable.
- **`sBIT`.** Honoured through the undocumented `SPNG_DECODE_USE_SBIT` flag, which rescales
  samples by their significant bits ([`spng.h`][decode-flags-h]).

Chunk-order rules are enforced per chunk (`cHRM` after `PLTE` is `SPNG_ECHUNK_POS`, a second
`gAMA` is `SPNG_EDUP_GAMA`), but both errors are in the recoverable list, so the default outcome
is that the offending chunk is dropped ([`spng.c`][chunk-order], [recovery list][read-chunks-discard]).
See [image metadata][c-metadata].

### 4. I/O and codec architecture

The answers to the codec questions, in one place:

| Question              | Answer at the pinned revision                                                                                                                                                                                                       |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Push or pull          | Pull: `spng_rw_fn` must supply exactly `length` bytes or fail ([`context.md`][context-rw])                                                                                                                                          |
| Incremental           | Only through a blocking callback; no partial-input return                                                                                                                                                                           |
| Progressive           | Row by row (`spng_decode_row`, `spng_decode_scanline`), Adam7 rows out of order with `spng_get_row_info`                                                                                                                            |
| Suspendable           | No. A callback that cannot supply bytes ends the decode with `SPNG_IO_EOF` or `SPNG_IO_ERROR`, which invalidates the context                                                                                                        |
| Row or tile callbacks | No callbacks; the caller pulls rows                                                                                                                                                                                                 |
| Region decode         | No. Rows can be discarded after decoding; columns cannot be skipped, and inflate is sequential                                                                                                                                      |
| Downscaled decode     | No. Adam7 passes are decoded but there is no API to stop after pass N and get a low-resolution image                                                                                                                                |
| Zero-copy input       | Yes for buffers (`buffer_read_fn` advances a pointer); streams copy through an 8 KiB buffer                                                                                                                                         |
| Inflate backend       | zlib or miniz via `SPNG_USE_MINIZ`; disabling Adler-32 checks requires a suitable zlib (`inflateValidate`, documented as 1.2.11 or later) and is unavailable with miniz ([`spng.c`][inflate-init], [`decode.md`][decode-checksums]) |
| Encoder               | Same context with `SPNG_CTX_ENCODER`; adaptive filter choice per row (`get_best_filter`), output to a stream or an internal buffer                                                                                                  |

Truncation behaves differently by input mode (**verified**). A 256 by 256 random-content
greyscale image cut at 60% of its bytes and fed through `spng_set_png_stream` delivered 127 of
256 rows before `spng_decode_row` returned `SPNG_IO_EOF`. The same cut fed through
`spng_set_png_buffer` delivered none: buffer mode reads a whole `IDAT` chunk at once, so the
progressive initialisation itself failed with `SPNG_IO_EOF`. The documentation warns of this:
_"getting a partial image is possible with progressive decoding but is not guaranteed to work in
all cases. The decoder issues read callbacks that can span multiple rows or even the whole image,
partial reads are not processed"_ ([`decode.md`][decode-errors]).

### 5. Hostile input and safety

**Limits and their defaults.** Dimension and chunk-size defaults are the format's maxima,
and the cache defaults to `SIZE_MAX`; the allocating-chunk count has a finite default of 1000
([`spng.c`][ctx-new2], [`context.md`][context-limits], [`decode.md`][decode-options]):

| Limit                            | Setter                                            | Default                       | Enforced on                                                                     |
| -------------------------------- | ------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------- |
| Width, height                    | `spng_set_image_limits`                           | 2^31 − 1 each (`spng_u32max`) | `IHDR`, in `check_ihdr`                                                         |
| Decoded image bytes              | none; the caller checks `spng_decoded_image_size` | unbounded                     | caller                                                                          |
| Chunk size                       | `spng_set_chunk_limits(chunk_size, …)`            | 2^31 − 1                      | growth of inflated `iCCP`, `zTXt`, `iTXt`; sub-8-KiB caveat below               |
| Chunk cache (allocated metadata) | `spng_set_chunk_limits(…, cache_limit)`           | `SIZE_MAX`                    | `eXIf`, text, `sPLT`, unknown chunks, inflated metadata; sub-8-KiB caveat below |
| Stored chunk count               | `SPNG_CHUNK_COUNT_LIMIT` option                   | 1000 (`SPNG_MAX_CHUNK_COUNT`) | `eXIf`, text, `sPLT` and unknown chunks; `iCCP` is not counted                  |
| Total input, work, time          | none                                              | none                          | none                                                                            |

The documentation is explicit that untrusted input needs all three caller actions: set image
limits, check `spng_decoded_image_size` _"against a constant limit"_, and _"Set a chunk size and
chunk cache limit with `spng_set_chunk_limits()` to control memory usage and avoid DoS from
decompression bombs"_ ([`decode.md`][decode-untrusted]). What the defaults allow (**verified**):

- A 100,000 by 100,000 RGBA 16-bit `IHDR` passes default limits; `spng_decoded_image_size`
  reports 80,000,000,000 bytes. With `spng_set_image_limits(ctx, 16384, 16384)` the same file
  fails with `SPNG_EUSER_WIDTH`.
- An `eXIf` chunk whose header declares 0x7FFFFFF0 bytes, in a 45-byte file ending after four
  payload bytes, made the context request one allocation of 2,147,483,632 bytes before the payload was
  read; the call then failed with `SPNG_IO_EOF`. With 1 MiB chunk limits, it failed with
  `SPNG_ECHUNK_LIMITS` and allocated nothing. The handler charges `chunk.length` to the cache and
  then `malloc`s it in full ([`spng.c`][exif-handler]); the declared length is trusted up to the
  cache limit.
- A `zTXt` payload of 65,248 bytes expanding to 64 MiB of text made `spng_get_text` allocate a
  67,108,865-byte buffer with default limits. With a 1 MiB chunk limit, `spng_get_text` failed with
  `SPNG_ECHUNK_LIMITS`, and the following `spng_decode_image` returned `SPNG_EBADSTATE`:
  `SPNG_ECHUNK_LIMITS` is not in the recoverable list, so an oversized _ancillary_ chunk kills the
  pixel decode as well.
- With `spng_set_chunk_limits(ctx, 1024, 8192)`, a `zTXt` expanding to 4,096 text bytes
  was accepted (**verifier probe**). The inflater starts with 8 KiB regardless of the bound,
  checks the bound only when doubling, and ignores the final cache-accounting error
  ([`spng.c`][inflate-stream]). Small configured limits are therefore not hard bounds.
- `spng_set_option(ctx, SPNG_CHUNK_COUNT_LIMIT, 100)` on a fresh context returns `1` (failure), as
  does `5000`; only `0` succeeds. The setter rejects any value greater than the number of chunks
  already counted, which is zero before decoding ([`spng.c`][count-limit]):
  `if(value > (int)ctx->chunk_count_total) return 1;`. The comparison looks inverted; as written,
  the documented "configurable" count limit can only be lowered to zero on a fresh context.

**Checksums.** `spng_set_crc_action(ctx, critical, ancillary)` takes `SPNG_CRC_ERROR`,
`SPNG_CRC_DISCARD` (ancillary only) or `SPNG_CRC_USE`; the defaults are error for critical and
discard for ancillary chunks ([`spng.c`][crc-action], [`spng.h`][crc-enum]). `SPNG_CRC_USE` also
turns off Adler-32 checking for the corresponding chunk kind via `inflateValidate`
([`spng.c`][inflate-init]). At the pin, `read_header` also skips critical CRCs when only the
ancillary action is `SPNG_CRC_USE`, because its second branch lacks an ancillary-kind check
([`spng.c`][read-header]) (**verified**: a `PLTE` with a corrupted CRC failed with
`SPNG_ECHUNK_CRC` under the defaults and decoded with return `0` after
`spng_set_crc_action(ctx, SPNG_CRC_ERROR, SPNG_CRC_USE)`). Because a CRC is
checked when the _next_ header is read, the last `IDAT`'s CRC is not checked by
`spng_decode_image` (**verified**): a file whose only `IDAT` has a corrupted CRC decoded with
return `0`, and the error, `SPNG_ECHUNK_CRC`, appeared only when `spng_decode_chunks` was called
afterwards. A corrupted Adler-32 was reported by `spng_decode_image` itself (`SPNG_EIDAT_STREAM`).
A corrupted `tEXt` CRC was discarded silently and the decode succeeded; the verifier's
follow-up `spng_get_text` returned `SPNG_ECHUNKAVAIL`.

**Lenience findings (verified).** A file with two `PLTE` chunks decoded successfully and used the
second palette; issue 275 reports libpng rejecting its duplicate-palette test file, and upstream added the check on November 13, 2026, after the
pin, in response to issue 275 ([commit `272c9f29e5`][commit-plte], [issue 275][issue-275]).
Palette indices past the palette's end decode as opaque black, as documented
([`decode.md`][decode-errors]); that is bounds-safe by construction, because `decode_plte` is a
256-entry table in the context; palette RGB entries start zeroed and all 256 alpha entries are
initialised to 255 unless `tRNS` applies ([`spng.c`][palette-init]). Calling
`spng_decode_row` after a failed progressive initialisation returned `SPNG_EINTERNAL` rather than
`SPNG_EBADSTATE`; upstream added state checks to `spng_decode_scanline` on November 10, 2026
([commit `8288236fa2`][commit-state]).

**Arithmetic.** The overflow checks the README promises are present in the size calculations
(`calculate_scanline_width`, `calculate_image_width`, `increase_cache_usage`). One encoder-side
check is dead: `require_bytes` guards its doubling loop with `if(new_size / SIZE_MAX > 2)`, which
is never true, so the intended overflow test does not run ([`spng.c`][dead-check]). Reaching it
needs attempted buffer growth past `SIZE_MAX / 2`. Reachability was not established on either
32- or 64-bit targets; this was read, not run.

**Vulnerability history.** The author's web search found no libspng CVE, but that does not
establish that none exists. The NVD API returned HTTP 503 on November 14 and again on
November 15, 2026. OSV lists 11 OSS-Fuzz issues, all published in June and
July 2020 against development commits ([OSV query][osv-list]). Each record gives only the
crash type, the crash stack and the introducing and fixing commits; the root causes below are
not stated in the records and were not reconstructed. Three cover the classic memory-safety
classes of a hand-written C parser:

- [OSV-2020-227][osv-227], a heap double free in `spng__free`, with the stack
  `spng__inflate_stream` then `read_non_idat_chunks`. The stack locates the crash on the
  metadata-inflate path; it does not establish the ownership mistake that caused it.
- [OSV-2020-200][osv-200], a heap-buffer-overflow write of 2 bytes in `spng_decode_scanline`,
  reached from `spng_decode_row` and `spng_decode_image`. The record does not identify the
  particular buffer or conversion responsible.
- [OSV-2020-360][osv-360], a heap use-after-free read in `read_chunks_after_idat` (a function
  absent from the pinned revision, where `read_non_idat_chunks` handles chunks on both sides of
  the `IDAT` sequence).

The release notes of 0.7.2 add a fourth, reported in a public issue from the reporter's own fuzzing output:
_"Fixed encoder heap overflow with specially crafted images"_, a `memset` past the end of a
buffer in `encode_row` for an interlaced 4-bit image ([issue 196][issue-196], [releases][releases]).
The README's claim of _"No known security bugs"_ rests on the policy that _"vulnerabilities are
fixed before they become public"_ ([`README.md`][readme-features]). See [hostile input][c-hostile]
and the [hostile-input papers thread][p-hostile].

### 6. Allocation and ownership

All allocation goes through the context's `spng_alloc`, including zlib's ([`spng.c`][alloc]).
The image buffer is always the caller's. The context owns parsed metadata: strings returned by
`spng_get_text`, `spng_get_iccp` and `spng_get_exif` point into it and are freed by
`spng_ctx_free` ([`chunk.md`][chunk-text]). In the other direction, data handed to
`spng_set_splt` or `spng_set_unknown_chunks` _"should be a valid reference for the lifetime of the
context"_, and the `user` bitfield records which chunks the caller owns so that
`spng_ctx_free` does not free them ([`chunk.md`][chunk-set], [`spng.c`][ctx-free]). Decode scratch
is two scanline buffers sized to the widest Adam7 pass plus 32 bytes, an interlace row buffer,
and the optional 16-bit gamma table ([`spng.c`][scanline-buf]). The encoder's internal output
buffer grows by doubling and becomes the caller's after `spng_get_png_buffer`
([`spng.c`][get-png-buffer]).

### 7. CPU parallelism and SIMD

No threading: `pthread.h` is included under `SPNG_MULTITHREADING` and then unused
([`spng.c`][multithreading]). SIMD covers defiltering and, on ARM, palette expansion:

- **x86.** SSE2 implementations of Sub, Avg and Paeth for 3- and 4-byte pixels, derived from
  libpng's code ([`spng.c`][simd-license]). The ISA level is a compile-time macro, `SPNG_SSE`
  (1 to 4); level 3 uses `_mm_abs_epi16`, level 4 `_mm_blendv_epi8`
  ([`spng.c`][sse-levels], [intrinsics][sse-intrinsics]). _"Currently only SSE2 optimizations are tested"_
  ([`build.md`][build-opts]).
- **AArch64.** NEON versions of the same filters plus `expand_palette_rgba8_neon` and
  `expand_palette_rgb8_neon`, which gather four or eight palette entries per iteration with lane
  loads ([`spng.c`][neon-palette]). _"NOTE: only arm64 builds are tested!"_ ([`spng.c`][simd-select]).
- **Runtime dispatch.** One function only: `defilter_up` carries
  `__attribute__((target_clones("default,avx2")))`, enabled when the build probe
  `tests/target_clones.c` links (GCC and glibc on x86-64) ([`spng.c`][target-clones],
  [`target_clones.c`][tc-probe]). Every other SIMD path is chosen by the preprocessor, and an
  unknown architecture falls back to scalar code with a `#pragma message`.
- **Up filter** is scalar on purpose: `defilter_scanline` jumps to the plain loop for
  `SPNG_FILTER_UP`, leaving it to the compiler's auto-vectoriser (and the AVX2 clone).

Sub, Avg and Paeth for 1-, 2-, 6- and 8-byte pixels, and all filtering in the encoder, use
scalar source loops. Up uses the auto-vectorisable loop at every pixel size. Inflate
speed is whatever the linked zlib provides.

### 8. GPU offload and interop

No GPU offload. libspng produces host bytes and has no planar output. The caller can supply
CPU-writable mapped or externally allocated memory to `spng_decode_image` or the progressive row
API, which permits direct decoding into a suitably laid-out [staging buffer][c-staging]
([`decode.md`][decode-formats]).

### 9. Temporal, animation and containers

APNG is not supported. The README lists _"Animated PNG"_ as _"Planned"_
([`README.md`][readme-features]); `acTL`, `fcTL` and `fdAT` are unknown chunks to the parser, and
an `fdAT` after the `IDAT` sequence is either discarded or kept as raw bytes. PNG is the only
container. APNG is now part of the PNG specification's third edition ([W3C PNG third edition][png3]),
so this is a gap against the current standard, not only against libpng's patched builds.

### 10. Testing and conformance

The test suite needs a developer build (`meson configure -Ddev_build=true`) and libpng
1.6.0 or later; the fallback Meson wrap pins 1.6.37
([`tests/README.md`][tests-readme], [`tests/meson.build`][tests-meson], [`libpng.wrap`][libpng-wrap]). It is a
differential test against libpng over PngSuite (175 images in `tests/images`, the README's count, among
them `exif2c08.png` with an `eXIf` chunk): for each image and each output format and flag combination, both libraries decode and
_"the output images have to be bit-identical, for gamma-corrected images each color / grayscale
sample has to be within 2%"_ ([`tests/README.md`][tests-readme], [`testsuite.c`][compare]).
Chunk contents are compared too (`compare_chunks`). `tests/crashers` holds 27 regression
files, many copied from libpng: one per oversized ancillary chunk type (`huge_iCCP_chunk.png`,
`huge_eXIf_chunk.png` and so on), bad CRC, bad Adler-32, zero width, zero `gAMA`, missing `PLTE`
([tree][crashers]).

Fuzzing runs on OSS-Fuzz with three targets built by [`ossfuzz.sh`][ossfuzz]:
`spng_read_fuzzer`, the same target with the libpng `png_mutator.h` structure-aware mutator
(from Google's `fuzzer-test-suite`, included with `-include` and
`PNG_MUTATOR_DEFINE_LIBFUZZER_CUSTOM_MUTATOR`), and `spng_write_fuzzer`. The read target derives the
output format, flags, input mode (buffer, stream, `FILE`), progressive mode and the ancillary CRC
action from the last four input bytes. It creates the context with `SPNG_CTX_IGNORE_ADLER32` and
sets `SPNG_CRC_USE` for critical chunks, so mutations are not rejected by checksum and the default
checksum configuration is never fuzzed. It caps dimensions at 200,000, decoded output at
80,000,000 bytes, and metadata at 4 MB per chunk and 8 MB in total, calls the getters before
decoding and checks text string invariants ([`spng_read_fuzzer.c`][read-fuzzer],
[getter checks][fuzzer-getters]). Seeds are the
repository's PNGs plus a dictionary ([`spng.dict`][dict]). Pull requests run CIFuzz for 900
seconds ([`ci-fuzz.yml`][cifuzz]), and the OSS-Fuzz corpora can be replayed as Meson tests with
the `oss_fuzz` option ([`tests/meson.build`][tests-meson]). Benchmarks live outside the
repository, in the `spngt` and `benchmark_images` wraps, both pinned to `head`
([`spngt.wrap`][spngt-wrap]).

**Maintenance.** Tags run from 0.2.0 to 0.7.4 (May 8, 2023), and the README calls releases from
0.4.0 on stable ([`README.md`][readme-versioning]); the release notes of 0.6.3
and the 0.7.0 series credit NLNet funding ([releases][releases]). Between the 0.7.4 release and
the pinned merge the repository received three non-merge commits (a README badge change in May 2023, a
CMake fix in December 2023 and a copyright-year update in August 2026), plus the merge itself. After the pin, eight
commits landed on November 10 to 13, 2026, fixing the duplicate `PLTE` acceptance, adding state
checks, preventing a second `spng_decode_image` call and switching gamma to `powf`
([commit list][commits]). Security reports go to one contact address, and only the most recent
release is supported ([`SECURITY.md`][security]).

---

## Lessons for Sparkles

- **Q4 — A context state machine with "invalid" as a terminal state is the right failure model,
  and D can expose it explicitly.** libspng's `decode_err` sets one field, but the row entry
  points omit the check; `SPNG_EINTERNAL` after a failed init demonstrates the gap, fixed upstream
  later. A D decoder can return `Expected!(Row, PngError)` and reject further work after a fatal
  error. `Expected` alone does not prevent callers from invoking the decoder again; that still
  needs an enforced state or ownership contract. The draft `sparkles:image` already
  returns `PngResult` with an offset ([existing code][bl-existing]).
- **Q4 — Pull with a blocking callback is not suspendable, and libspng shows the cost.** Its
  progressive API requires synchronous reads; in the single-`IDAT` truncation probe, buffer
  input yielded no rows while stream input yielded 127. The result depends on chunk boundaries
  and callback request sizes. A Sparkles decoder meant to sit
  on `sparkles:event-horizon` reads needs a push or resumable design ([Wuffs'][wuffs] coroutines, the
  survey's counterpoint) that returns "short read" with its state intact
  ([concepts][c-suspend], [event-horizon baseline][bl-eh]). Both existing Sparkles PNG decoders are
  whole-file and single-shot (G7 in the [baseline][bl-existing]); libspng's row API would be a
  step, not the target.
- **Q4, Q8 — Lazy metadata parsing behind getters is convenient and hides cost.** A call named
  `spng_get_text` can allocate 64 MiB (verified). A D design that parses metadata on demand
  should make the budget an argument or a property of the decoder value, not an ambient context
  setting, and should decide whether an over-budget ancillary chunk is skipped or fatal. libspng
  makes it fatal, which lets a hostile `zTXt` deny the image.
- **Q4, Q8 — Limits must default closed.** libspng's dimension and allocation defaults allow
  a caller that forgets `spng_set_chunk_limits` to get a 2 GiB allocation request from a 45-byte file
  (verified). Sparkles' existing `maxPngPixels = 1UL << 26` default is the opposite stance and
  matches the hostile-input thread's recommendations ([existing code][bl-existing],
  [papers][p-hostile]). The list of limits a D decoder needs is visible here: dimensions, decoded
  bytes, per-chunk raw length, per-chunk inflated length, total metadata, chunk count, and none
  of libspng's for total input or work.
- **Q8 — Test the limit setters, not only the limits.** The `SPNG_CHUNK_COUNT_LIMIT` setter is
  unable to accept a positive limit on a fresh context at the pin; the read fuzzer never calls
  it. The sub-8-KiB inflate bypass also needs boundary tests. A D limits struct still needs tests
  that check each field's effect on actual decoding, including small and exact-boundary budgets.
- **Q4 — Trailing-CRC formats need an explicit "verified" point.** libspng parses a chunk before
  its CRC arrives and undoes it later; for the last `IDAT` the CRC is checked only if the caller
  reads on. A D decoder over a range of chunks can make "pixels delivered" and "file verified"
  two distinct states, so a caller that needs integrity (golden tests, the `DBG1` byte-compared
  screenshots) can ask for the second.
- **Q3, Q7 — Defiltering is a SIMD candidate, and dispatch should be at run time.** libspng picks
  SSE2 or NEON at compile time and uses `target_clones` for a single function. The repository's
  host-SIMD precedent already does run-time dispatch by hand ([shaders and SIMD baseline][bl-shaders],
  G5). Its Paeth kernels for 3 and 4 bytes per pixel are candidates to profile and port; this
  review did not measure their share of decode time.
- **Q2 — Explore a compile-time output format parameter.** libspng's conversion source branches
  over `fmt` and colour type, with whole-row fast paths for some combinations. D can
  instantiate the conversion loop per (source colour type, depth, target format) and keep a thin
  run-time switch at the top. A benchmark and generated-code inspection must establish whether
  that improves on the C compiler's existing optimisation.
- **Q5 — Parse every colour chunk, apply none by default.** libspng returns `gAMA`, `cHRM`,
  `sRGB` and `iCCP` raw and offers only a fixed-2.2 gamma transform. That is a reasonable floor
  for a codec; the missing piece is `cICP`, `mDCV` and `cLLI` from PNG's third edition, which a
  Sparkles PNG decoder written now should carry as typed metadata from the start
  ([concepts][c-cicp]).
- **Q8 — The differential harness is the transferable asset.** libspng's tests decode every
  PngSuite file in every supported output format with both libraries and require bit identity, with a 2%
  tolerance for gamma. That is the shape Sparkles' `png_oracle.d` lacks (byte-exact,
  single-format, stb_image only, G11 in [existing code][bl-existing]). libspng is a candidate
  second oracle: one C file needing only zlib, which suits ImportC (not tried here), and a
  lineage independent of stb_image.
- **Q8 — Fuzz targets should encode configuration in the input.** The read fuzzer's trailing
  four bytes select format, flags, input mode and progressive mode, so one corpus covers the API
  surface. A D fuzz target over a `sparkles:image` decoder can do the same with the decoder's
  options struct.
- **Q9 — One file, one context, codec plus encoder.** libspng's single-translation-unit layout
  and absence of a pixel type are what make it easy to vendor, and what keep it a codec rather
  than an image library. That is evidence that a PNG codec does not need an image-core package
  beneath it, only a row sink.

## Strengths

- A small, coherent API: one context type, four calls for the common decode, integer errors, no
  `setjmp`.
- Covers the whole PNG 1.2 feature set including Adam7, 16-bit, `sBIT`, `tRNS`, every standard
  ancillary chunk and `eXIf`, plus an encoder with adaptive filtering.
- Explicit, documented limits for dimensions, chunk size, metadata cache and chunk count, and a
  documented recipe for untrusted input.
- Zero-copy parsing from caller buffers; two scanlines of decode scratch.
- A real differential test suite against libpng over PngSuite, a regression corpus of crashers,
  and continuous OSS-Fuzz plus CIFuzz coverage, with a structure-aware mutator.
- Custom allocator threaded through to zlib.

## Weaknesses

- Not suspendable: a blocking pull callback, and buffer mode that needs whole `IDAT` chunks.
- Dimension and memory limits default open despite the finite chunk-count default; a hostile
  header triggers a 2 GiB allocation and a small `zTXt` a 64 MiB one (verified). Inflated metadata
  can exceed configured sub-8-KiB limits (verifier probe).
- The chunk-count limit setter rejects every positive value on a fresh context (verified), and
  strict mode has no setter.
- Lenient by default: duplicate `PLTE` was accepted until a post-pin fix; the final `IDAT` CRC is
  verified only if the caller keeps reading (verified).
- No `cICP`, `mDCV`, `cLLI` or APNG, all now in the PNG specification.
- SIMD is compile-time apart from one function; only SSE2 and arm64 are tested.
- Sparse maintenance: no release since May 2023 and three non-merge commits plus the merge
  between that release and the pin; fixes resumed in November 2026, after the pinned revision.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                           | Trade-off                                                                                            |
| ----------------------------------------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| One opaque context for decoder, encoder, metadata and zlib state  | Simple API; no separate info struct; one free call                  | Cannot share parsed metadata across decodes; the context is large and mutable                        |
| Pull I/O with a callback that must fill the request               | Mirrors libpng; easy to write against `FILE` and memory             | Not suspendable; a non-blocking source cannot be used without threads                                |
| Output format chosen at run time from eight values                | Shared conversion code plus whole-row fast paths                    | Branches in the source; compiled cost unmeasured; partial `G8`/`GA8`/`GA16`; no premultiplied output |
| Lenient defaults: discard bad ancillary chunks and CRCs           | Matches libpng on files in the wild                                 | Corruption goes unreported; strict mode exists internally but cannot be enabled                      |
| Parse first, undo on bad CRC                                      | CRC trails the data; streaming parse without buffering whole chunks | The last `IDAT` CRC is unchecked unless the caller reads on                                          |
| Large default dimension and memory limits; count defaults to 1000 | Avoid restrictive size defaults                                     | Caller must budget memory; small inflated limits have gaps; over-limit metadata is fatal             |
| Lazy metadata parse behind getters                                | Parsing begins when a getter or decode requires it                  | Getters can block and allocate; requesting one type also parses other preceding metadata             |
| Compile-time SIMD from libpng's intrinsics; `target_clones` once  | Reuses tested code; dispatch limited to one function                | Default x86 intrinsics use SSE2; AVX2 clone only for Up; other compiler vectorisation unexamined     |
| Single C file, zlib or miniz backend                              | Small vendoring surface; ImportC compatibility untested             | Inflate speed and Adler-32 control depend on the linked zlib; miniz drops `SPNG_CTX_IGNORE_ADLER32`  |

## Sources

- libspng source at `46c81dc2b`: [`spng/spng.c`][spng-c], [`spng/spng.h`][spng-h], the
  [`docs/`][docs-dir] directory, [`README.md`][readme], [`SECURITY.md`][security], the
  [`tests/`][tests-readme] tree and [`tests/ossfuzz.sh`][ossfuzz].
- Upstream history read through the GitHub API on November 14 and rechecked on November 15, 2026: [commits][commits],
  [releases][releases], [issue 196][issue-196], [issue 275][issue-275].
- OSV records of the OSS-Fuzz issues: [OSV-2020-227][osv-227], [OSV-2020-200][osv-200],
  [OSV-2020-360][osv-360], and the [OSV query][osv-list].
- The PNG specification, third edition: [W3C PNG third edition][png3].
- Sparkles context: [existing code baseline][bl-existing], [shaders and SIMD baseline][bl-shaders],
  [event-horizon baseline][bl-eh], [hostile-input papers][p-hostile], [concepts][concepts];
  sibling deep-dives [libpng][libpng], [Wuffs][wuffs], [stb_image][stb], [image-rs][image-rs], [zune-image][zune] (which benchmarks against libspng)
  and [Skia][skia] (whose PNG codecs lack CICP in libpng mode).
- Probes: two C programs compiled against the pinned `spng.c` with zlib 1.3.2, GCC 14.3.0,
  `-fsanitize=address,undefined`, in `/tmp/spng-probe`; not committed. The verifier rebuilt
  them with GCC 16.2.0 and the same zlib and sanitizer flags in `/tmp/libspng-verify-epypAA`
  and ran `./probe`, `./probe2` and a follow-up `./extra`, using
  `nix develop -c bash -c '…'` from the repository root for compilation.
  A second verifier's independent probe, `v.c` and `v2.c` in `/tmp/spng-claude-verify-qh3OpF`,
  was built the same way. These results have no committed CI fixture.

<!-- References -->

[repo]: https://github.com/randy408/libspng
[site-docs]: https://libspng.org/docs/
[spng-c]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c
[spng-h]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.h
[meson]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/meson.build#L1-L5
[docs-dir]: https://github.com/randy408/libspng/tree/46c81dc2b3747fa43aac33704c890a468f195d6e/docs
[readme]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/README.md
[readme-intro]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/README.md#L9-L10
[readme-motivation]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/README.md#L15-L18
[readme-features]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/README.md#L24-L41
[readme-security]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/README.md#L110-L121
[readme-versioning]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/README.md#L123-L130
[readme-known]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/README.md#L136-L141
[security]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/SECURITY.md
[decode-md]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/decode.md
[decode-errors]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/decode.md#L32-L75
[decode-checksums]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/decode.md#L77-L106
[decode-memory]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/decode.md#L108-L133
[decode-untrusted]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/decode.md#L135-L146
[decode-formats]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/decode.md#L187-L232
[decode-progressive]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/decode.md#L234-L281
[decode-options]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/decode.md#L317-L328
[context-md]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/context.md
[context-rw]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/context.md#L24-L42
[context-new2]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/context.md#L138-L145
[context-limits]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/context.md#L175-L203
[chunk-md]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/chunk.md
[chunk-semantics]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/chunk.md#L1-L21
[chunk-iccp]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/chunk.md#L73-L81
[chunk-text]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/chunk.md#L97-L117
[chunk-set]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/chunk.md#L324-L351
[migrate]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/migrate-libpng.md#L1-L10
[build-opts]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/docs/build.md#L36-L60
[errno]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.h#L33-L123
[fmt-enum]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.h#L167-L182
[decode-flags-h]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.h#L190-L199
[crc-enum]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.h#L201-L213
[row-info]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.h#L427-L433
[multithreading]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L25-L27
[read-size]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L29-L32
[simd-select]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L36-L71
[state-enum]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L85-L101
[boilerplate]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L114-L125
[decode-flags]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L153-L164
[chunk-bitfield]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L178-L198
[ctx-struct]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L227-L364
[alloc]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L398-L437
[image-size]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L562-L713
[check-fmt]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L631-L650
[decode-err]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L756-L761
[dead-check]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L826-L846
[read-header]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L1021-L1095
[read-chunk-bytes]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L1097-L1115
[inflate-init]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L1182-L1216
[inflate-stream]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L1237-L1356
[scanline-bytes]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L1358-L1422
[target-clones]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L1438-L1446
[check-exif]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L2189-L2203
[small-chunk]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L2248-L2263
[non-idat-loop]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L2358-L2412
[chunk-order]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L2456-L2493
[exif-handler]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L2691-L2724
[read-chunks-discard]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3141-L3210
[read-scanline]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3216-L3255
[conversion-loop]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3336-L3522
[decode-scanline-tail]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3524-L3548
[decode-row]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3551-L3606
[flevel]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3645-L3664
[scanline-buf]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3667-L3706
[zerocopy]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3765
[gamma-lut]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3767-L3810
[palette-init]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3878-L3914
[first-filter]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L3983-L3990
[ctx-new2]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L4891-L4947
[ctx-free]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L4949-L5008
[buffer-read]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L5010-L5022
[set-input]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L5048-L5111
[get-png-buffer]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L5113-L5136
[crc-action]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L5182-L5196
[count-limit]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L5256-L5262
[simd-license]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L6146-L6180
[sse-levels]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L6183-L6197
[sse-intrinsics]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L6384-L6415
[neon-palette]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/spng/spng.c#L6929-L6976
[tc-probe]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/target_clones.c
[tests-readme]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/README.md
[tests-meson]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/meson.build#L28-L51
[compare]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/testsuite.c#L71-L82
[crashers]: https://github.com/randy408/libspng/tree/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/crashers
[read-fuzzer]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/spng_read_fuzzer.c#L30-L100
[fuzzer-getters]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/spng_read_fuzzer.c#L105-L193
[ossfuzz]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/ossfuzz.sh#L20-L50
[dict]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/tests/spng.dict
[cifuzz]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/.github/workflows/ci-fuzz.yml#L1-L23
[libpng-wrap]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/subprojects/libpng.wrap
[spngt-wrap]: https://github.com/randy408/libspng/blob/46c81dc2b3747fa43aac33704c890a468f195d6e/subprojects/spngt.wrap
[commits]: https://github.com/randy408/libspng/commits/master
[commit-plte]: https://github.com/randy408/libspng/commit/272c9f29e5aea0241e1fe962d963e7632a1c04f0
[commit-state]: https://github.com/randy408/libspng/commit/8288236fa20f98e548c161c260753d37164c1972
[releases]: https://github.com/randy408/libspng/releases
[issue-196]: https://github.com/randy408/libspng/issues/196
[issue-275]: https://github.com/randy408/libspng/issues/275
[osv-list]: https://osv.dev/list?ecosystem=OSS-Fuzz&q=libspng
[osv-227]: https://osv.dev/vulnerability/OSV-2020-227
[osv-200]: https://osv.dev/vulnerability/OSV-2020-200
[osv-360]: https://osv.dev/vulnerability/OSV-2020-360
[png3]: https://www.w3.org/TR/png-3/
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-suspend]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-hostile]: ./concepts.md#hostile-input
[c-cicp]: ./concepts.md#cicp
[c-icc]: ./concepts.md#icc-profile
[c-gainmap]: ./concepts.md#hdr-gain-map
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-metadata]: ./concepts.md#image-metadata
[c-staging]: ./concepts.md#staging-and-upload
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-eh]: ./baseline/event-horizon.md
[p-hostile]: ./papers/hostile-input-safety.md
[image-rs]: ./image-rs.md
[zune]: ./zune-image.md
[skia]: ./skia.md
[libpng]: ./libpng.md
[wuffs]: ./wuffs.md
[stb]: ./stb-image.md
