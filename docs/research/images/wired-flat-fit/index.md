# wired against PNG, QOI and ISOBMFF: the Flat fit experiment

A paper exercise and a prototype that put three image formats against `sparkles:wired`, once against the unmerged Flat binary-format draft and once against the specs and code that ship today, to collect evidence for catalog question Q4: what must the wired binary description format express?

| Field          | Value                                                                                                                                                                                                                   |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Subject        | `sparkles:wired`: the Flat draft (paper exercise) and the shipped schema, checks and format concept (prototype)                                                                                                         |
| Question       | [Q4][umbrella-q] of the umbrella; the requirement list it yields is [`wired-requirements.md`][reqs]                                                                                                                     |
| Flat revision  | `docs/specs/wired/flat/{SPEC,PLAN,open-issues}.md` at `8a454ce151c23b3608467cf8e19821678583ecb3` of `origin/docs/wired-flat` ([SPEC][flat], [open issues][flat-issues]), `status: draft`, `reviewed: 2026-10-16`        |
| Shipped wired  | [base spec][wired-spec] (`status: accepted`), [expressiveness][expr-spec], [SDL][sdl-spec], and `libs/wired/src` on branch `feat/images` at `b12945057647bde26f2504dc0552a9cb760306d2`                                  |
| Formats        | PNG from the [W3C PNG Third Edition][png3]; QOI from the [QOI specification 1.0][qoi]; ISOBMFF (ISO/IEC 14496-12) as the [MPEG reference software][mpeg-repo] and [libavif's parser][avif-repo] implement and quote it  |
| Prior art read | [Wuffs][wuffs], [libpng][libpng], [libspng][libspng], [libavif][libavif], [libwebp][libwebp]; [Kaitai Struct][bf-kaitai], [Construct][bf-construct], [DFDL][bf-dfdl] and the [binary-formats comparison][bf-comparison] |
| Compilers      | DMD 2.112.1; LDC 1.43.0, both from the repository's `nix develop` shell                                                                                                                                                 |
| Programs       | [`png-chunks.d`][ex-png], [`qoi.d`][ex-qoi], [`isobmff.d`][ex-isobmff]                                                                                                                                                  |
| Category       | Experiment (wave 3), formats                                                                                                                                                                                            |
| Last reviewed  | November 15, 2026                                                                                                                                                                                                       |

> [!IMPORTANT]
> This page records evidence; it makes no design decision, and the wired design it
> measures is work in progress. Every claim carries one of three labels.
> **Verified**: a program in [`examples/`][ex-dir] compiled and ran with both
> compilers and printed what is quoted. **Documented**: read in a spec or in source
> at the cited revision. **Assessment**: reasoning about how a format would be written
> in the Flat draft's vocabulary. No Flat code exists anywhere, so every Flat column
> below is an assessment, never a test.

## Overview

### What it answers

The [wired baseline][bl-wired] lists what wired can express and leaves open how well
that fits real image framing (G1 to G6). The [Wuffs deep-dive][wuffs-desc] turns a
real decoder into thirteen behaviours a description would have to cover. This page
takes three formats that span the shapes image work meets and writes them down twice:

- **PNG**: a big-endian chunk stream with a trailing CRC, chunk kinds whose presence
  and length depend on an earlier chunk, ordering rules, one zlib stream split across
  `IDAT` chunks, and APNG's sequence-numbered frames.
- **QOI**: a 14-byte header, then a byte-aligned op stream whose tags are 2 or 8 bits
  wide and whose meaning depends on running decoder state, then an 8-byte end marker.
- **ISOBMFF as AVIF and HEIF use it**: self-sized nested boxes with a 64-bit escape
  and a "to end of file" size, FullBox versions and 24-bit flags, fields whose width
  comes from data, and references by item ID and property index across the tree.

Each format gets a row per construct with three columns: what the Flat draft would do,
what the shipped wired does in the prototype, and the gap. A section per cross-cutting
need follows, with what Wuffs, Kaitai Struct and DFDL do about it.

### How to read the two columns

**Flat** means the draft's vocabulary as written: fixed records proved at compile
time, `@FlatEndian`, `@FlatConst`, `@FlatBits`, counted and byte-length dynamic members
(`@FlatCount`, `@FlatBytes`, `@FlatRest`), offsets, conditional fields, `FlatTagged`
unions, `FlatSelect` and record parameters ([Flat SPEC §3 to §5][flat]). It is a reader over
borrowed bytes with a builder for the library's own arena files.

**Current wired** means what a program can use today: `wireSchemaOf!(F, T)` and its
`SchemaNode` arena, the format-marker concept with its schema-validation hook,
`@WireCheck` with `isBetween` and `isOneOf`, and `wireCheckFailures`. No binary
backend ships, so the prototype writes a small one, and everything it cannot get from
the schema is hand-written D marked `GAP` in the source.

## How the prototype works

All three programs share one walker, about 180 lines, copied into each so that each
stays a single file; the copies differ only in each program's error kinds.

- **The format marker.** `struct BeFixed` declares `validateWireSchema`, the hook that
  `wireSchemaOf` calls when a marker defines it (`schema.d`, lines 535 to 537), and
  admits only shapes whose byte size the schema determines. The byte order lives in the
  marker, because a `SchemaNode` has no such field: its members are `kind`,
  `scalarKind`, `scalarBits`, `nullAwareKind`, names, an enum value, edges, a
  reference index, `staticLength`, annotations and a `PolicySnapshot` (`schema.d`,
  lines 104 to 122). **Documented.**
- **Sizes from the schema.** `fixedSize` sums `scalarBits / 8` over integer, character
  and enumeration leaves and multiplies by `staticLength` for static arrays; any
  sequence, map, union or string returns `-1`. **Verified:** the schema gives 8 bytes
  for the PNG chunk header, 13 for `IHDR`, 26 for `fcTL`, 14 for the QOI header and
  20 for the `hdlr` fixed part.
- **Reading and writing.** `readNode` and `writeNode` recurse over the schema in
  lockstep with the D type, as the expressiveness spec's schema-driven walk describes
  ([§2.2][expr-walk]): the schema supplies kinds, widths and array lengths, the marker
  supplies big-endian order. `decodeFixed` makes one bounds check for the whole record,
  runs field checks as each field is read, then type-level checks. An enumeration
  value that is not a member becomes `notAMember`.
- **Encode runs the checks.** `encodeFixed` refuses a value whose checks fail, as
  [expressiveness §6.4][expr-check] requires ("Checks run inside decode ... and inside
  encode"). The negative fixtures therefore write invalid records through `writeNode`
  directly, which bypasses the checks.

Four observations about the shipped layer came out of writing it:

1. **Check descriptors are not in the schema.** Expressiveness §6.4 says checks
   carrying `isOneOf` or `isBetween` "record it in the schema, so a help/schema emitter
   can print the constraint". **Verified:** the annotation on `ChunkHeader.length`,
   declared as `@WireCheck!(isBetween!(0u, 0x7FFF_FFFFu))`, is the string
   `WireCheck!(isBetween, "", AnyFormat)`; the bounds are gone. The
   [expressiveness plan][expr-plan] lists "check descriptors in the schema" as open
   under E6, so this is a known gap, not drift. A binary backend that wanted to turn a
   range check into a compile-time fact, or a requirement checker that wanted to print
   it, has only the predicate to call.
2. **`wireCheckFailures` allocates.** It appends to a `WireCheckFailure[]`
   (`policy.d`, line 200 onward), so the prototype's read path is not `@nogc`, as the
   [baseline][bl-wired] already records. Error text is built by concatenation for the
   same reason. **Documented.**
3. **No 24-bit leaf.** A FullBox's flags are `bit(24)`; the prototype declares
   `ubyte[3]` and assembles the value by hand (`flagsOf`). Flat has `FlatU24`
   ([`WFL1`][flat]). **Verified** by the `FullBoxHeader` size of 4 bytes.
4. **Passing the schema as an `in` parameter breaks CTFE.** `fixedSize` takes the
   schema as `const WireSchema`. **Verified:** changing it to `in WireSchema` (the
   package builds with `-preview=in`) makes DMD 2.112.1 stop with "variable `schema`
   cannot be read at compile time" inside `validateWireSchema`, and makes LDC 1.43.0
   crash with `AssertError@dmd/dinterpret.d(641)`. Any CTFE helper a binary layer adds
   over `WireSchema` needs a test on both compilers.

### Running the programs

```bash
nix develop -c dub run --temp-build --single docs/research/images/wired-flat-fit/examples/png-chunks.d --compiler=dmd
nix develop -c dub run --temp-build --single docs/research/images/wired-flat-fit/examples/png-chunks.d --compiler=ldc2
```

**Verified:** each of the three programs exits 0 under DMD and LDC, the two compilers
print byte-identical output, and a second run prints the same bytes. Without
`--temp-build`, dub leaves the executable beside the source. The programs build every
input in memory and depend only on `sparkles:wired` by path.

## PNG

The PNG datastream is an 8-byte signature followed by chunks; each chunk is a 4-byte
length that "counts only the data field, not itself, the chunk type, or the CRC", a
4-byte type, the data, and "A four-byte CRC calculated on the preceding bytes in the
chunk, including the chunk type field and chunk data fields, but not including the
length field" ([§5.3][png-layout]). Integers are big-endian and four-byte unsigned
integers are limited to 2^31 - 1 ([§7.1][png-int]).

A Flat description would be shaped like this. It is a sketch to make the table
concrete, written in the draft's syntax and never compiled:

```d
@FlatEndian(Endian.bigEndian)
@WireCheck!(c => c.length <= 0x7FFF_FFFF, "chunk length above 2^31 - 1")
struct Chunk
{
    uint length;
    uint type;
    // The CRC cannot be a field of its own: WFL4 rejects a fixed field after a
    // dynamic member, so data and CRC are one byte array of length + 4.
    @FlatBytes!(plusCrc, "length") ubyte[0] dataAndCrc;
}

@FlatEndian(Endian.bigEndian)
struct PngFile
{
    @FlatConst([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ubyte[8] signature;
    @FlatRest Chunk[0] chunks;   // sequential: each element sizes itself (WFL33)
}
```

| Construct                                        | Flat (assessment)                                                                                                                                                                                                                                                                                                                                            | Current wired (prototype)                                                                                                       | Gap                                                                                                   |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Signature ([§5.2][png-sig])                      | `@FlatConst` on a `ubyte[8]`; `WFL25` says "a leaf", and §2.1 makes every `WFL1` type that is not a record a leaf, static arrays included, so the text admits it; no example in the draft uses one, and how `constantMismatch` carries an 8-byte value is not stated                                                                                         | hand-written compare (`pngSignature`)                                                                                           | Flat: confirm array constants; current: no binary backend, a check could carry it                     |
| Chunk header: length and type                    | fixed record with `@FlatEndian` and a type-level `@WireCheck` (`WFL28`); a type of letters only is a check                                                                                                                                                                                                                                                   | `ChunkHeader` with `@WireCheck` on both fields; **verified** 8 bytes                                                            | none for the header itself                                                                            |
| Chunk data, length-prefixed                      | `@FlatBytes!(rule, "length")` (`WFL29`–`WFL31`)                                                                                                                                                                                                                                                                                                              | hand-written `readChunk`                                                                                                        | current: no dynamic members at all                                                                    |
| CRC after the data                               | not a field: `WFL4` rejects "a field that is neither dynamic nor conditional after ... a dynamic member", so the CRC is folded into `dataAndCrc`                                                                                                                                                                                                             | hand-written                                                                                                                    | **both**: no trailer after a variable member                                                          |
| CRC-32 over type and data ([§5.5][png-crc])      | no: a check sees "the value `flatDecode` produces" (`WFL28`) and its dynamic members "are empty" (`WFL20`)                                                                                                                                                                                                                                                   | hand-written `crc32` over two ranges; **verified** a flipped IHDR CRC bit gives `badCrc at offset 8`                            | **both**: no checksum over a declared byte range                                                      |
| `IHDR` fields and Table 12                       | fixed record; field ranges and the colour-type and bit-depth table as type-level checks (`WFL28`)                                                                                                                                                                                                                                                            | `Ihdr` with field and type-level `@WireCheck`; **verified** depth 16 with indexed colour is refused                             | none                                                                                                  |
| Chunk kind dispatch                              | `FlatTagged!(uint, 4, Endian.bigEndian, 'IHDR', Ihdr, ...)` (`WFL38`), but an unmatched tag "must produce `unknownVariant`", while PNG says a decoder "can safely ignore" an unknown ancillary chunk ([§5.4][png-naming])                                                                                                                                    | `switch` on the type; unknown ancillary skipped, unknown critical refused by bit 5 of the first byte                            | **both**: no default branch, no rule keyed on a bit of the tag                                        |
| `PLTE` and `tRNS` by colour type                 | if `IHDR` is declared as a fixed prefix of the root (as Kaitai's `png.ksy` does), `colorType` could be passed as a parameter (`WFL40`) to select the `tRNS` layout (`WFL39`), provided a nested record's leaves count as "in scope", which §5.2 does not state; the `tRNS` length bound by the `PLTE` count is between two sibling elements and has no scope | hand-written, with the [§11.2.2][png-plte] and [§11.3.1.1][png-trns] rules                                                      | **both**: no check across elements of a sequence                                                      |
| Ordering ([§5.6, Table 7][png-order])            | no: a check cannot see the elements of a dynamic member                                                                                                                                                                                                                                                                                                      | hand-written; **verified** `tRNS` before `PLTE` and a `tEXt` between `IDAT`s are refused                                        | **both**: no first, last, at-most-once, consecutive or before-X rules                                 |
| `IDAT` run as one zlib stream ([§10.2][png-fsl]) | the sequential range yields each chunk; joining payloads is code                                                                                                                                                                                                                                                                                             | hand-written: every `IDAT` body is fed to one inflater; **verified** 2 `IDAT` chunks give one 10-byte stream, as `IHDR` implies | **both**: no "payloads of this run form one stream"                                                   |
| Expected inflated size                           | no derived values; budgets are traversal bytes and depth (`WFL24`)                                                                                                                                                                                                                                                                                           | hand-written `expectedInflated`                                                                                                 | **both**: no output-size contract from header fields                                                  |
| `cICP` ([§11.3.2.6][png-cicp])                   | fixed 4-byte record; "Matrix Coefficients shall be set to 0" as a check                                                                                                                                                                                                                                                                                      | `Cicp` with `isOneOf!(0)`; **verified** matrix 1 is refused at offset 43                                                        | none                                                                                                  |
| APNG `acTL`, `fcTL` ([§11.3.6][png-actl])        | fixed records; "0 is not a valid value" as a check; the frame region inside `IHDR` needs `IHDR` values as parameters, but a `WFL28` check receives only "the value `flatDecode` produces", which holds fields, not parameters                                                                                                                                | `Actl`, `Fctl` records; region rule hand-written; **verified** a frame outside the canvas is refused                            | Flat: checks do not see parameters as written; current: no context into checks                        |
| `fdAT` and sequence numbers ([§4.9.2][png-seq])  | `fdAT` is a 4-byte number then `@FlatRest` frame data; "ascending order, with no gaps or duplicates" spans chunks                                                                                                                                                                                                                                            | hand-written; **verified** a gap gives `badSequence`                                                                            | **both**: no counter across elements; `num_frames` equal to the `fcTL` count is the same kind of rule |
| Encode                                           | the builder writes arena formats (`WFL47`–`WFL49`), not foreign files; the draft "does not ... write OpenType fonts" ([Flat introduction][flat])                                                                                                                                                                                                             | `encodeFixed` for records; length and CRC computed by hand (`putChunk`); **verified** `IHDR` re-encodes byte-identically        | **both**: no computed length or checksum on write                                                     |

**Verified** output of [`png-chunks.d`][ex-png]:

```text
png: schema sizes: ChunkHeader 8, IHDR 13, cICP 4, acTL 8, fcTL 26 bytes
png: schema annotation on ChunkHeader.length: WireCheck!(isBetween, "", AnyFormat)
png: valid: 260 bytes, 11 chunks, IHDR 4x2 indexed depth 8, 3 palette entries
png: valid: cICP 1/13/0/1, acTL frames 2 plays 0, fcTL seen 2
png: valid: 2 IDAT chunks -> one zlib stream of 10 bytes (IHDR implies 10); fdAT frame 3 bytes
png: round trip: IHDR re-encoded to 13 bytes, identical: true
png: bit flip in IHDR CRC: badCrc at offset 8 (IHDR)
png: depth 16 with indexed colour: checkFailed at offset 16 (Ihdr: bit depth not allowed for colour type)
png: tRNS before PLTE: badOrder at offset 69 (tRNS before PLTE)
png: tEXt between IDATs: badOrder at offset 187 (IDAT chunks must be consecutive)
png: fdAT sequence gap: badSequence at offset 221 (fdAT sequence_number)
png: frame outside the canvas: checkFailed at offset 183 (fcTL region outside IHDR)
png: cICP matrix coefficients 1: checkFailed at offset 43 (Cicp.matrixCoefficients: matrix coefficients must be 0 for RGB)
png: cut inside IHDR: truncated at offset 8 (IHDR)
```

Of the 15 rows, the schema-derived part of the prototype covers the fixed records:
the chunk header, `IHDR`, `cICP`, `acTL` and `fcTL`, about 90 lines of declarations and comments.
The walk over chunks, the CRC, presence, ordering, stream joining and sequence numbers
are about 240 lines of hand-written D. Flat would add the length-prefixed body and
the per-kind dispatch, and stop at the same boundary. [Kaitai's `png.ksy`][ksy-png]
draws the line in the same place: the CRC is a plain `u4`, `IDAT` bodies are raw
bytes, and chunks repeat with `repeat-until: _.type == "IEND" or _io.eof`.

## QOI

"A QOI file consists of a 14-byte header, followed by any number of data "chunks" and
an 8-byte end marker" ([QOI 1.0][qoi]). The header is `char magic[4]` ("qoif"),
big-endian `uint32_t` width and height, and two informative bytes, `channels` (3 or 4)
and `colorspace` (0 or 1).

| Construct                               | Flat (assessment)                                                                                                                                                                                                       | Current wired (prototype)                                                                                              | Gap                                                                         |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| 14-byte header                          | fixed record, `@FlatConst` magic, checks on the two bytes                                                                                                                                                               | `QoiHeader` with `@WireCheck`; **verified** 14 bytes, 7 schema nodes; `Qoif` and channels 5 refused                    | none                                                                        |
| Width times height budget               | no caller limit on a derived value; `WFL24` counts traversal bytes                                                                                                                                                      | hand-written: checked against `maxPixels` before allocating; **verified** a 16-pixel budget refuses the 32-pixel image | **both**: limits on header-derived quantities are code                      |
| Op tags: 8-bit before 2-bit             | `FlatTagged` matches one tag value per variant (`WFL38`); a 2-bit tag is 64 byte values, and "The 8-bit tags have precedence over the 2-bit tags", so it would need 256 variants, each with its own `@FlatConst` record | hand-written dispatch                                                                                                  | **both**: no masked or prioritised tag match                                |
| Sub-byte fields (`DIFF`, `LUMA`, `RUN`) | `@FlatBits` inside a `ubyte` leaf (`WFL27`) covers the field positions; the biases (2, 32, 8, -1) are arithmetic                                                                                                        | hand-written shifts and masks                                                                                          | current: no bit ranges; Flat: covered as layout                             |
| Running index and previous pixel        | not description: "A running array[64] ... of previously seen pixel values is maintained by the encoder and decoder"                                                                                                     | decoder state                                                                                                          | none expected: codec code                                                   |
| End of the op stream                    | the stream ends when "all pixels specified by width * height have been covered", a count in decoded units; `@FlatRest` can only hand over ops and marker together                                                       | hand-written                                                                                                           | **both**: no member whose extent the consumer reports                       |
| 8-byte end marker                       | a constant at a position known only after decoding                                                                                                                                                                      | hand-written; **verified** a final `0x00` gives `badEndMarker`, a trailing byte `trailingBytes`                        | **both**: as above                                                          |
| Input in pieces                         | no: the input is one borrowed slice (`WFL9`) and `truncated` is terminal (`WFL11`)                                                                                                                                      | `QoiDecoder.feed(piece, closed)` resumes anywhere, partial ops in a 14-byte scratch; **verified** below                | **both**: no "need more" outcome; current wired has no binary reader at all |
| Encode                                  | builder is for arenas only                                                                                                                                                                                              | header by `encodeFixed`; ops by hand after the reference `qoi.h` choice order                                          | none expected for ops; header covered                                       |

**Verified** output of [`qoi.d`][ex-qoi]. The image is 8 by 4 pixels chosen to use
every op; it is decoded whole and in pieces of 1, 3 and 7 bytes, with identical pixels
each time:

```text
qoi: schema: header 14 bytes, 7 nodes
qoi: encoded 32 pixels into 73 bytes (14 header + 51 ops + 8 end)
qoi: pieces of 73: 8x4 ch 4, ops rgb 4 rgba 1 index 18 diff 2 luma 3 run 4, suspensions 0, pixel hash 5be2eef34b9e45ec, round trip true
qoi: pieces of 1: 8x4 ch 4, ops rgb 4 rgba 1 index 18 diff 2 luma 3 run 4, suspensions 72, pixel hash 5be2eef34b9e45ec, round trip true
qoi: pieces of 3: 8x4 ch 4, ops rgb 4 rgba 1 index 18 diff 2 luma 3 run 4, suspensions 24, pixel hash 5be2eef34b9e45ec, round trip true
qoi: pieces of 7: 8x4 ch 4, ops rgb 4 rgba 1 index 18 diff 2 luma 3 run 4, suspensions 10, pixel hash 5be2eef34b9e45ec, round trip true
qoi: round trip: header re-encoded to 14 bytes, identical: true
qoi: magic Qoif: checkFailed at offset 0 (QoiHeader.magic: magic is not qoif)
qoi: channels 5: checkFailed at offset 12 (QoiHeader.channels: channels must be 3 or 4)
qoi: budget of 16 pixels: limitExceeded at offset 14 (pixel count above the caller's budget)
qoi: cut after 20 op bytes, fed in pieces of 1: truncated at offset 34 (op)
qoi: end marker ends in 0x00: badEndMarker at offset 73 (end marker)
qoi: one run of 62 for 32 pixels: badStream at offset 15 (run past the last pixel)
qoi: bytes after the end marker: trailingBytes at offset 73 (bytes after the end marker)
```

The cut input shows the distinction Wuffs draws with `closed`: fed one byte at a time,
the decoder returned "need more" after every piece and reported `truncated` only when
the caller closed the input. The header is the one place the schema helps, and even
there the resumable path had to collect the 14 bytes before `decodeFixed` could run:
the schema walk needs the whole record in one slice. The QOI specification says
nothing about a zero width or height; the prototype refuses them, which is its own
choice, not a rule of the format.

## ISOBMFF

ISO/IEC 14496-12 §4.2.2 defines the box header that libavif quotes field by field:
`unsigned int(32) size; unsigned int(32) type = boxtype;`, then
`unsigned int(64) largesize` when `size` is 1, then `unsigned int(8) usertype[16]`
when the type is `uuid`; "if size is 0, then this box shall be in a top-level box
(i.e. not contained in another box), and be the last box in its 'file'"
([`stream.c`][avif-boxheader]). A FullBox adds an 8-bit version and 24-bit flags,
which the MPEG reference reads as one 32-bit word split into `val >> 24` and
`val & 0xffffff` ([MPEG `MP4Atoms.c`][mpeg-fullbox]). AVIF and HEIF hang an item graph
off `meta`: `pitm` names the primary item, `iinf` lists items, `iloc` locates their
bytes, `iprp` holds `ipco` (a list of properties) and `ipma` (which items use which
property) ([libavif item graph][libavif-graph]).

A Flat box header would be shaped like this (sketch, never compiled):

```d
@FlatEndian(Endian.bigEndian)
struct BoxHeader
{
    uint size;
    uint type;                                          // a four-character code
    @FlatPresentIf!(isOne, "size") ulong largesize;     // WFL37
    @FlatPresentIf!(isUuid, "type") ubyte[16] usertype; // WFL37
    // WFL37: "A conditional field that follows an absent one is absent
    // whatever its own condition says", so usertype is never read when
    // largesize is absent; neither order of the two fields is correct.
    // size counts the header too, and 0 means "to the end of the file":
    // neither @FlatBytes nor @FlatRest can be chosen by a value.
}
```

| Construct                                         | Flat (assessment)                                                                                                                                                                                                                                                                          | Current wired (prototype)                                                                                          | Gap                                                                      |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| 32-bit `size` and four-character `type`           | fixed record                                                                                                                                                                                                                                                                               | `BoxHeader`; **verified** 8 bytes                                                                                  | none                                                                     |
| `largesize` when `size` is 1                      | `@FlatPresentIf` after the fixed part (`WFL37`); a 64-bit leaf is admitted (`WFL1`)                                                                                                                                                                                                        | hand-written; **verified** the `mdat` box with a 16-byte header                                                    | current: no conditional fields                                           |
| `uuid` extended type                              | `@FlatPresentIf` on `type` is admissible (`type` is a `uint` leaf in scope, `WFL29`, `WFL37`), but absence is monotone: a conditional field after an absent one "is absent whatever its own condition says" (`WFL37`), so `usertype` cannot follow an optional `largesize`, nor precede it | hand-written; **verified** a 24-byte header                                                                        | **both**: no independent optional fields; current: no conditional fields |
| Body length = `size` minus header                 | a rule function can subtract (`WFL29`, `WFL30`), but its arguments would include `largesize`, which may be absent; a decoded copy holds `.init` for an absent field (`WFL20`), but the draft does not say what a rule sees                                                                 | hand-written; `size` below the header is `badSize`                                                                 | Flat: rules over conditional fields unspecified                          |
| `size` 0: to the end, top level only              | no: `@FlatRest` is a static choice, not selected by a value                                                                                                                                                                                                                                | hand-written; **verified** size 0 inside `ipco` is refused, at the top level accepted                              | **both**: no sentinel length, no "top level only" rule                   |
| FullBox version and 24-bit flags                  | fixed `ubyte` and `FlatU24` (`WFL1`); `@FlatBits` on the flags                                                                                                                                                                                                                             | `FullBoxHeader` with `ubyte[3]`; version bound per box hand-written                                                | current: no 24-bit leaf                                                  |
| Children inside the parent's size                 | a body of `@FlatBytes` holding a sequential array of boxes; region containment is per root (`WFL34`, `WFL36`), so a child overrunning its parent is caught only if the body is its own region                                                                                              | hand-written; **verified** an `ispe` overrunning `ipco` gives `truncated`                                          | Flat: nested regions not stated for sequential elements                  |
| Box-type dispatch, recursive                      | `FlatTagged` on `type` at offset 4; recursion is in the draft's visit table (`WFL2`) but the spike "covered neither ... `FlatTagged` nor recursion" ([baseline][bl-wired]); unknown boxes give `unknownVariant`, but readers skip unknown boxes                                            | hand-written `walk`                                                                                                | **both**: no default branch; Flat: recursion unproven                    |
| Version-dependent widths (`pitm`, `iinf`, `ipma`) | `FlatSelect` on `version` (`WFL39`) with the version passed as a parameter (`WFL40`)                                                                                                                                                                                                       | hand-written `readVar` with width 2 or 4                                                                           | current: none; Flat: workable                                            |
| `iloc` field widths from 4-bit fields             | `@FlatBits` gives `offset_size`, `length_size`, `base_offset_size`, `index_size`; each selects 0, 4 or 8 bytes for later fields, so an extent would need `FlatSelect` over 3 × 3 × 3 combinations, and `FlatSelect` selects by one value                                                   | hand-written; **verified** `offset_size` 3 is refused                                                              | **both**: no field whose width is a value                                |
| `ipma` 7- or 15-bit index plus essential bit      | `FlatSelect` on `flags & 1` between two association records, each with two `@FlatBits` ranges                                                                                                                                                                                              | hand-written masks                                                                                                 | current: no bit ranges                                                   |
| References by ID and index                        | no: offsets name byte positions (`WFL34`), not keys; `pitm` → `iinf`, `iloc` → items, `ipma` → items and 1-based `ipco` indices are lookups                                                                                                                                                | hand-written `resolve` after the walk; **verified** a missing item, a missing property and an extent past the file | **both**: no key and reference vocabulary                                |
| Extents into `mdat`                               | an offset is at most 32 bits (§5.3); `iloc` allows 8-byte offsets and lengths                                                                                                                                                                                                              | hand-written, 64-bit arithmetic with an overflow check                                                             | **both**: no 64-bit offsets                                              |
| Encode                                            | builder is for arenas only                                                                                                                                                                                                                                                                 | `BoxWriter` back-patches every size and the `iloc` offsets; **verified** the `ftyp` header re-encodes identically  | **both**: no computed sizes or offsets on write                          |

**Verified** output of [`isobmff.d`][ex-isobmff], abridged to the tree and the
failures (the full run prints 30 lines):

```text
isobmff: valid: 353 bytes, 16 boxes, brand avif ["avif", "mif1", "miaf"], handler pict
isobmff:   ftyp @0 header 8 size 28
isobmff:   uuid @28 header 24 size 28 usertype 0123456789abcdef
isobmff:   meta @56 header 8 size 244
isobmff:     iloc @176 header 8 size 48
isobmff:     iprp @224 header 8 size 76
isobmff:       ipco @232 header 8 size 44
isobmff:       ipma @276 header 8 size 24
isobmff:   mdat @300 header 16 size 41 largesize
isobmff:   free @341 header 8 size 12 size 0 (to end)
isobmff: iloc version 1, field sizes offset 4 length 4 base_offset 0 index 0
isobmff: item 1 (primary) av01 "Color": 17 bytes at 316, inside mdat true, properties: ispe=64x48 pixi(essential)=[8, 8, 8]
isobmff: ispe overruns ipco: truncated at offset 240 (ispe overruns its parent)
isobmff: size 0 inside ipco: badSize at offset 260 (size 0 below the top level)
isobmff: iloc offset_size 3: checkFailed at offset 188 (iloc field size 3)
isobmff: Exif extent past the file: badReference at offset 176 (item 2 extent outside the file)
isobmff: ipma names property 3 of 2: badReference at offset 276 (item 1 names property 3 of 2)
isobmff: pitm names item 7: badReference at offset 101 (pitm names item 7, absent from iinf)
isobmff: ftyp size 4: badSize at offset 0 (size 4 smaller than its header)
```

### What the two implementations show

Reading the two parsers side by side turned up three places where hand-written
framing diverges from the text it implements. All three are **documented** (read at
the pinned revisions, not run):

- **Field order in the box header.** libavif reads `largesize` and then `usertype`,
  the order of §4.2.2 ([`stream.c`][avif-boxheader]). The MPEG reference reads the
  16-byte `uuid` type first and `largesize` after it
  ([`MP4Atoms.c`, lines 832 to 853][mpeg-atom]), so a `uuid` box with `size` 1 is read
  at the wrong offsets there. The same function turns `size` 0 into "the rest of the
  input" at any depth (lines 805 to 816), where libavif refuses it below the top level.
- **The `ipma` essential bit.** In the 16-bit association form the reference software
  writes `propertyIndex->essential = (u8)(propertyIndex->property_index & (1 << 15));`,
  which truncates `0x8000` to 0, so the essential flag is never set and bit 15 stays
  in the index; the 8-bit form tests the bit correctly
  ([`ItemPropertyAssociationAtom.c`, lines 214 to 232][mpeg-ipma]), and the writer
  sets both correctly (lines 112 to 121). libavif reads the
  two widths with one bit reader call each (`avifROStreamReadBitsU8` for the flag,
  then 15 or 7 bits, [`read.c`][avif-ipma]).
- **An assertion on data.** The same reference function ends with
  `assert(self->bytesRead == self->size);` (line 237), where the Flat draft's `WFL12`
  says no input value may cause an assertion failure.

None of the three would arise from a description that declares the field order once,
names a bit range once for both directions, and turns a size mismatch into a value.
That is evidence for declarative bit ranges and for one description serving decode
and encode; it is not evidence that the reference software is widely deployed as a
parser, which it is not claimed to be.

## Cross-cutting needs

Each section states what the three formats need, then what Flat, the shipped wired,
Wuffs, Kaitai Struct and DFDL do. Wuffs is a codec language, not a description
format, and is included as the reference for what decoders do in code.

### Bit-level fields

**Need.** QOI's `DIFF` packs three 2-bit fields and `LUMA` a 6-bit and two 4-bit
fields; ISOBMFF's `iloc` packs four 4-bit width fields into two bytes and `ipma` a
1-bit flag with a 7- or 15-bit index. All stay inside one byte-aligned integer.
Entropy-coded payloads (the zlib inside `IDAT`, the AV1 inside `mdat`) need bit
streams that cross bytes, but those are codec code in every implementation read.

- **Flat**: `@FlatBits!(name, shift, width)` names a range inside one unsigned leaf
  (`WFL27`), enough for every byte-aligned case above; crossing byte boundaries is
  excluded "from every milestone" (O9). Whether the builder writes bit ranges is not
  stated: `WFL48` writes leaves.
- **Current wired**: none; the prototype shifts and masks by hand.
- **Wuffs**: bit fields are code over `bits` and `n_bits` state with refill
  ([deflate][wuffs-deflate-bits]); byte-aligned header fields are read whole and
  masked ([Wuffs deep-dive][wuffs-desc]).
- **Kaitai Struct**: bit-sized integers `bN` with big- and little-endian bit order,
  declared per field ([user guide, "Bit-sized integers"][ksy-guide-bits]).
- **DFDL**: `lengthUnits` of bits and a `bitOrder` property per element
  ([DFDL deep-dive][bf-dfdl-wire]).

### Computed lengths and offsets

**Need.** A PNG chunk's data length is its `length` field; an ISOBMFF box's body is
`size` (or `largesize`) minus a header of 8, 16, 24 or 32 bytes, or "to the end" when
`size` is 0; an `iloc` extent is `base_offset + extent_offset` in 64 bits.

- **Flat**: rules are values in scope or functions of them, computed in checked `ulong`
  (`WFL29`, `WFL30`); offsets are 8 to 32 bits with record, ancestor or region bases
  (§5.3, `WFL34`). Missing: a length that includes the header, a sentinel that selects
  "rest", rules over absent conditional fields, 64-bit offsets.
- **Current wired**: none for bytes. [Expressiveness §7.2][expr-ctx] defers sibling
  access during decode: "Sibling field access during decode is deliberately not in this
  revision".
- **Wuffs**: `io_limit (io: args.src, limit: (this.chunk_length as base.u64))` scopes a reader to a length
  ([PNG][wuffs-png-pass]); positions are 64-bit `pos + ri` ([I/O][wuffs-io-position]).
- **Kaitai Struct**: `size:` takes any expression and opens a substream with its own
  bounds; `quicktime_mov.ksy` writes the whole box rule as one value instance,
  `len32 == 0 ? (_io.size - 8) : (len32 == 1 ? len64 - 16 : len32 - 8)`, and has no
  `uuid` branch ([`quicktime_mov.ksy`][ksy-mov]).
- **DFDL**: `lengthKind` of `explicit`, `prefixed` or `endOfParent`, with expressions
  over earlier values ([DFDL deep-dive][bf-dfdl-wire]).

### Checksums

**Need.** PNG's CRC-32 covers the type and the data, not the length, and trails both;
the zlib Adler-32 inside the `IDAT` stream covers decompressed bytes. Policy differs
by chunk class: libspng errors on critical chunks and discards bad ancillary ones by
default ([libspng][libspng-crc]); Wuffs has `QUIRK_IGNORE_CHECKSUM`
([Wuffs quirks][wuffs-quirks]); the PNG specification says "A CRC should be checked
before processing the chunk data" ([§13.1][png-errcheck]).

- **Flat**: no; a check cannot see payload bytes (`WFL20`, `WFL28`), and the baseline's
  G4 says so.
- **Current wired**: no.
- **Wuffs**: CRC-32 over `mark`/`since` ranges of the reader, incremental across
  suspensions ([PNG chunks][wuffs-png-chunks]); verification is on by default, and
  `QUIRK_IGNORE_CHECKSUM` turns it off.
- **Kaitai Struct**: none; `png.ksy` stores the CRC as a plain `u4`
  ([`png.ksy`][ksy-png-crc]).
- **DFDL**: Daffodil has checksum layers: "A checksum layer computes a numeric value
  from a region of the data stream", delivered into a DFDL variable; it is "suitable
  only for checksums computed over small sections of data", since "The entire region of
  data the checksum is being computed over will be pulled into a byte buffer in memory"
  ([`ChecksumLayer.java`][dfdl-checksum]).

### Value constraints and dependent presence

**Need.** Field ranges (bit depth in {1, 2, 4, 8, 16}, matrix coefficients 0),
cross-field tables (PNG Table 12), presence that depends on another chunk (`PLTE`
required for colour type 3, forbidden for 0 and 4; `tRNS` layout by colour type),
version-dependent fields (FullBox).

- **Flat**: field and type-level checks on the decoded fixed part (`WFL28`),
  `@FlatSince` and `@FlatPresentIf` on values in the same record (`WFL37`), parameters
  from the enclosing record (`WFL40`). Dependence on a sibling element of a sequence
  has no scope.
- **Current wired**: `@WireCheck` at field and type sites, demonstrated by all three
  programs; checks receive the value only, so the `fcTL`-inside-`IHDR` rule is code.
  The `ref Ctx` of [§7.2][expr-ctx] could carry it, but the
  [expressiveness plan][expr-plan] lists `ref Ctx` threading as still open (E7),
  and the shipped `wireCheckFailures` passes the value alone.
- **Wuffs**: `if` statements in code, with proof obligations ([Wuffs deep-dive][wuffs-desc]).
- **Kaitai Struct**: `valid:` on a field, `if:` for presence, and `_root` to reach any
  earlier value: `png.ksy` selects the `tRNS` body by `if:` and
  `switch-on: _root.ihdr.color_type`
  ([`png.ksy`][ksy-png-trns]), which works because the file declares `IHDR` as a fixed
  prefix of the root ([`png.ksy`][ksy-png-seq]).
- **DFDL**: XSD facets plus `dfdl:assert`; the deep-dive warns that "optional
  validation failures must not influence parsing behavior", so a rejecting condition
  must be an assert, not a facet ([DFDL deep-dive][bf-dfdl-hostile]).

### Ordering and cardinality rules

**Need.** PNG's Table 7: `IHDR` first, `IEND` last, `PLTE` once and before `IDAT`,
`IDAT` consecutive, `cICP` before `PLTE` and `IDAT`, `acTL` before `IDAT`; APNG's
`num_frames` "must equal the number of fcTL chunks". libavif allows each of `iloc`,
`pitm`, `idat`, `iprp`, `iinf`, `iref` and `grpl` at most once in `meta`
([libavif][libavif-graph]).

- **Flat**: none; checks do not see dynamic members.
- **Current wired**: none.
- **Wuffs**: state bits in code; WebP's `variant` tracks which chunks have been seen
  ([Wuffs deep-dive][wuffs-desc]).
- **Kaitai Struct**: only the end condition of a repetition (`repeat-until`); the
  ordering rules are not in `png.ksy`.
- **DFDL**: sequences are ordered by the schema, and `occursCountKind` bounds
  occurrences; a rule such as "at most once, anywhere among ancillary chunks" is not
  shown in the deep-dive (not verified).

### A payload that is itself a compressed stream

**Need.** PNG: "The concatenation of the contents of all the IDAT chunks makes up a
zlib datastream", and the chunk boundaries "can fall anywhere in the zlib datastream"
([§10.2][png-fsl]); each APNG frame's stream is the `fdAT` payloads after their
4-byte sequence numbers. ISOBMFF: an item's bytes are its extents, possibly several,
in `mdat` or `idat`.

- **Flat**: the sequential range visits each chunk; joining payloads is code, and the
  draft "does not compress" ([Flat introduction][flat]).
- **Current wired**: none; the prototype feeds every `IDAT` body to one inflater
  without concatenating.
- **Wuffs**: the PNG decoder passes each `IDAT` body to `zlib.transform_io?` under an
  `io_limit`, with the inflater's state continuing across chunks ([PNG][wuffs-png-pass]).
- **Kaitai Struct**: `process: zlib` decompresses one field: `png.ksy` uses it for an
  `iCCP` profile ([`png.ksy`][ksy-png-iccp]), but not for `IDAT`, because no field holds
  the joined stream; the guide notes that processing "is available only to raw byte
  arrays or user types" ([user guide, "Processing"][ksy-guide-bits]).
- **DFDL**: Daffodil ships a gzip layer ([`GZipLayer.java`][dfdl-gzip]); a layer
  applies to a contiguous region, so a stream split by framing is likewise out of reach
  (assessment).

### References by ID across the tree

**Need.** `pitm` names an item ID that must exist in `iinf`; `iloc` and `ipma` entries
name items by ID; `ipma` names properties by a 1-based index into `ipco`, where 0 means
none and "the essential indicator shall also be 0" ([libavif][avif-ipma]).

- **Flat**: offsets name byte positions with a base (`WFL34`); there is no key and
  reference construct.
- **Current wired**: none; [`reference` nodes][expr-schema] close recursion in the
  schema, which is unrelated.
- **Wuffs**: no ISOBMFF decoder at the pinned revision ([Wuffs deep-dive][wuffs]).
- **Kaitai Struct**: expressions can index an array read earlier, but a lookup by key
  value across the tree is not shown in the surveyed files (not verified).
- **DFDL**: XPath expressions can navigate the infoset; whether DFDL admits XSD
  identity constraints for key and keyref checks was not verified.
- **libavif** does it in code after parsing, and a linear scan per ID makes many
  items quadratic ([libavif hostile input][libavif-hostile]).

### Streaming and suspendable parsing

**Need.** A file arriving from a socket or an `io_uring` read in pieces must parse
without the whole file in memory; truncation must be distinguishable from "not yet".
QOI shows the case at its smallest: a 5-byte op can straddle any boundary.

- **Flat**: no. The input is a borrowed whole region (`WFL9`), `truncated` is final
  (`WFL11`), and "The library does not obtain bytes" ([Flat introduction][flat]).
  O9 excludes cerealed-style values "whose size lives only in the stream", which is
  a different matter.
- **Current wired**: no binary reader; the JSON and SDL readers are whole-buffer.
- **Wuffs**: coroutines whose state lives in the receiver; a multi-byte read that
  straddles a buffer accumulates in a per-coroutine `scratch`, returns `"$short read"`,
  and resumes at the same point; a `closed` buffer turns the same shortage into an error
  ([coroutines][wuffs-coro], [I/O][wuffs-io]). The prototype's `QoiDecoder` copies this
  shape: one state struct, a 14-byte scratch, `needMore` while open, `truncated` once
  closed, sticky errors.
- **Other decoders**: libwebp checkpoints and replays (`SaveContext` per macroblock,
  `SaveState` every 8 rows, [libwebp][libwebp-idec]); libpng's push reader buffers each
  non-`IDAT` chunk whole before handling it ([libpng][libpng-io]); libspng has "no "need more input" return, so a source that does not have the bytes
  yet must block inside the callback" ([libspng][libspng-input]); libavif
  reads at most 32 bytes per top-level header and skips `mdat` by offset
  ([libavif][libavif-loop]).
- **Kaitai Struct**: needs a seekable stream; "Offset navigation needs a
  seekable/tellable stream ... It is not the same capability as a monotonic network
  stream reader" ([Kaitai deep-dive][bf-kaitai-access]).
- **DFDL**: speculative parsing may "retain input/state while exploring an alternative,
  then backtrack" ([DFDL deep-dive][bf-dfdl-access]); no suspension contract is
  recorded.

### Resource limits declared by the caller

**Need.** Budgets that stop a hostile file before allocation: pixel count and
dimensions (QOI's `width * height`, AVIF's `ispe`), chunk and metadata sizes, item,
extent and property counts, nesting depth.

- **Flat**: `FlatLimits.traversalBytes` and `maxDepth` (`WFL24`), provisional and
  measured on fonts only (O7).
- **Current wired**: `maxDepth = 1024` for JSON only ([baseline][bl-wired]).
- **Wuffs**: structural: a 24-bit dimension cap, exact work-buffer sizes, fixed
  internal arrays, and no work budget, since "Wuffs functions are not guaranteed to
  halt" ([Wuffs hostile input][wuffs-hostile]).
- **libavif**: `imageSizeLimit`, `imageDimensionLimit`, `imageCountLimit` and
  `sizeHint`, with no limit on item, extent or property counts
  ([libavif hostile input][libavif-hostile]); libspng: `spng_set_chunk_limits`
  ([libspng hostile input][libspng-hostile]).
- **Kaitai Struct**: "do not establish a universal allocation, depth, or traversal
  budget across all runtime languages" ([Kaitai deep-dive][bf-kaitai-hostile]).
- **DFDL**: the deep-dive finds no global time or memory bound in the standard
  ([DFDL deep-dive][bf-dfdl-hostile]).

### Encode as well as decode

**Need.** Writing PNG means computing each `length` and CRC; writing ISOBMFF means
back-patching every enclosing box size and every `iloc` offset once the bytes after
them are known, and choosing `iloc` field widths from the values; the MPEG reference
does the last by scanning items for any value above 32 bits
([`ItemLocationAtom.c`, lines 205 to 274][mpeg-iloc-size]).

- **Flat**: the builder writes the library's own arenas (`WFL47`–`WFL50`) with
  `link!"field"` fix-ups for offsets; it does not write foreign formats.
- **Current wired**: `@WireCheck` runs on encode ([§6.4][expr-check]) and
  `isWireRoundTrippable` is a compile-time predicate ([§8.2][expr-rt]); the prototype's
  `encodeFixed` honours the first. Lengths, CRCs and box sizes are hand-written
  (`putChunk`, `BoxWriter`). **Verified:** `IHDR`, the QOI header and the `ftyp` header
  re-encode byte-identically.
- **Wuffs**: "There is no encoder in `std/` at this revision" ([Wuffs deep-dive][wuffs]).
- **Kaitai Struct**: writing exists for Java and Python since v0.11, via `_check` and
  `_write`, but "does not eliminate placement/size work" ([Kaitai deep-dive][bf-kaitai-write]).
- **DFDL**: unparsing is part of the standard; `dfdl:outputValueCalc` derives an output
  field, for example a count, from the infoset ([DFDL deep-dive][bf-dfdl-vl]).
- **Construct**: `Rebuild` "derives output metadata rather than requiring callers to
  maintain both an array and an independent count" ([Construct deep-dive][bf-construct-vl]).

## Conclusion: the evidence

**Where the shipped wired already helps.** Fixed records with field and cross-field
checks, read and written by a schema walk, cover the PNG chunk header, `IHDR`, `cICP`,
`acTL`, `fcTL`, the QOI header and six ISOBMFF fixed parts, with byte-identical
re-encoding. What a binary backend needs from the schema and does not get is the byte
order, the check descriptors and a 24-bit leaf.

**Where the Flat draft would help.** Length-prefixed and byte-sized members, constants,
bit ranges inside one leaf, version-dependent fields, parameters and per-tag dispatch
cover most of the ISOBMFF header and the PNG chunk body, as far as reading goes; the
box header's two independent optional fields (`largesize`, `usertype`) are the
exception, because conditional absence is monotone (`WFL37`).

**Where neither helps, and every surveyed description language stops too.** A field
after a variable member (the PNG CRC), checksums over ranges, ordering and
cardinality across a sequence, a stream joined across chunks, references by ID,
sentinel lengths, widths chosen by data, suspension, caller budgets on derived
values, and computed fields on write. Wuffs and libavif do all of these in code over
a bounded reader. Kaitai and DFDL cover some through general expressions (`_root`,
`size:` expressions, `outputValueCalc`) and layers, and none of them covers CRC
placement, stream continuation and suspension together.

The pattern matches the Wuffs deep-dive's conclusion: headers and framing are
declarative in shape, and the rest is code that the framing hands bytes to. The
non-binding requirements that follow from this page are in
[`wired-requirements.md`][reqs].

## What CI needs to run the examples

The three programs depend only on `sparkles:wired` by path and need no network or
files. The working tree's `apps/ci/src/app.d` adds
`docs/research/images/wired-flat-fit/examples/*.d` to `ci --example-files`' default
set, beside `docs/research/images/mir-algorithm/examples/*.d`; until that change is
committed, CI does not run them.

## Sources

Specifications:

- W3C, [PNG Specification (Third Edition)][png3]: [§5.2][png-sig], [§5.3][png-layout],
  [§5.4][png-naming], [§5.5][png-crc], [§5.6][png-order], [§7.1][png-int],
  [§10.2][png-fsl], [§11.2.2][png-plte], [§11.3.1.1][png-trns], [§11.3.2.6][png-cicp],
  [§11.3.6][png-actl], [§4.9.2][png-seq], [§13.1][png-errcheck].
- [The Quite OK Image Format, Specification Version 1.0][qoi] (2022-01-05).
- ISO/IEC 14496-12, as quoted in [libavif `stream.c`][avif-boxheader] and implemented
  in the [MPEG reference software][mpeg-repo] at `689ac096a8e485385089341785c10271cf0684a8`.

Wired:

- Flat draft at the pinned revision: [SPEC][flat], [open issues][flat-issues].
- The shipped layer: [base spec][wired-spec] (`status: accepted`, [§3][wired-format]), [expressiveness spec][expr-spec],
  [expressiveness plan][expr-plan], [SDL spec][sdl-spec].
- Source read: `libs/wired/src/sparkles/wired/schema.d` (`SchemaNode`, `WireSchema`,
  the `validateWireSchema` hook) and `policy.d` (`WireCheck`, `isBetween`, `isOneOf`,
  `wireCheckFailures`).

Implementations and descriptions:

- [libavif][avif-repo] at `9b07a9d7a874b159bb4e14b80a6f08bb469d06f7`:
  [`avifROStreamReadBoxHeaderPartial`][avif-boxheader], [`iloc`][avif-iloc],
  [`ipma`][avif-ipma].
- MPEG reference: [`MP4Atoms.c`][mpeg-atom] (box header), [FullBox][mpeg-fullbox],
  [`ItemLocationAtom.c`][mpeg-iloc-size], [`ItemPropertyAssociationAtom.c`][mpeg-ipma].
- Kaitai Struct formats at `6739687e6af86bb1326953dc6cef7f8e716c10ec`:
  [`image/png.ksy`][ksy-png], [`media/quicktime_mov.ksy`][ksy-mov]; user guide at
  `43db335bbdd80ef3ad0bffa55e58de0b7037490b` ([bit-sized integers][ksy-guide-bits],
  [processing][ksy-guide-bits]).
- Apache Daffodil at `b5892e183284a0cd981d798541d45e0378611473`:
  [`ChecksumLayer.java`][dfdl-checksum], [`GZipLayer.java`][dfdl-gzip].
- Wuffs at `4be865da258c4b5e6d3e716fd4f36be016496a46`, through the
  [deep-dive][wuffs] and its pinned links.

Catalog pages: [umbrella][umbrella], [concepts][concepts], [wired baseline][bl-wired],
[Wuffs][wuffs], [libpng][libpng], [libspng][libspng], [libavif][libavif],
[libwebp][libwebp]; binary formats: [index][bf-index], [Kaitai Struct][bf-kaitai],
[Construct][bf-construct], [DFDL][bf-dfdl], [comparison][bf-comparison].

<!-- References -->

[umbrella]: ../index.md
[umbrella-q]: ../index.md#questions-this-survey-answers
[reqs]: ../wired-requirements.md
[concepts]: ../concepts.md
[bl-wired]: ../baseline/wired.md
[wuffs]: ../wuffs.md
[wuffs-desc]: ../wuffs.md#what-a-binary-description-format-would-have-to-express
[wuffs-hostile]: ../wuffs.md#_5-hostile-input-and-safety
[libpng]: ../libpng.md
[libpng-io]: ../libpng.md#_4-i-o-and-codec-architecture
[libspng]: ../libspng.md
[libspng-crc]: ../libspng.md#chunk-parsing-and-the-undo-log
[libspng-input]: ../libspng.md#input-buffer-stream-or-file
[libspng-hostile]: ../libspng.md#_5-hostile-input-and-safety
[libavif]: ../libavif.md
[libavif-graph]: ../libavif.md#the-item-graph-meta-iinf-iloc-ipco-ipma
[libavif-loop]: ../libavif.md#the-top-level-box-loop
[libavif-hostile]: ../libavif.md#_5-hostile-input-and-safety
[libwebp]: ../libwebp.md
[libwebp-idec]: ../libwebp.md#the-incremental-state-machine
[ex-dir]: ./examples/png-chunks.d
[ex-png]: ./examples/png-chunks.d
[ex-qoi]: ./examples/qoi.d
[ex-isobmff]: ./examples/isobmff.d
[bf-index]: ../../binary-formats/index.md
[bf-comparison]: ../../binary-formats/comparison.md
[bf-kaitai]: ../../binary-formats/kaitai-struct.md
[bf-kaitai-access]: ../../binary-formats/kaitai-struct.md#access-model
[bf-kaitai-hostile]: ../../binary-formats/kaitai-struct.md#hostile-input-safety
[bf-kaitai-write]: ../../binary-formats/kaitai-struct.md#weaknesses
[bf-construct]: ../../binary-formats/construct.md
[bf-construct-vl]: ../../binary-formats/construct.md#variable-length-and-optional-data
[bf-dfdl]: ../../binary-formats/dfdl.md
[bf-dfdl-wire]: ../../binary-formats/dfdl.md#wire-encoding
[bf-dfdl-access]: ../../binary-formats/dfdl.md#access-model
[bf-dfdl-vl]: ../../binary-formats/dfdl.md#variable-length-and-optional-data
[bf-dfdl-hostile]: ../../binary-formats/dfdl.md#hostile-input-safety
[wired-spec]: ../../../specs/wired/SPEC.md
[wired-format]: ../../../specs/wired/SPEC.md#_3-the-format-concept
[expr-spec]: ../../../specs/wired/expressiveness/SPEC.md
[expr-schema]: ../../../specs/wired/expressiveness/SPEC.md#_2-1-wireschemaof
[expr-walk]: ../../../specs/wired/expressiveness/SPEC.md#_2-2-the-schema-driven-walk
[expr-check]: ../../../specs/wired/expressiveness/SPEC.md#_6-4-validation-wirecheck
[expr-ctx]: ../../../specs/wired/expressiveness/SPEC.md#_7-2-context
[expr-rt]: ../../../specs/wired/expressiveness/SPEC.md#_8-2-iswireroundtrippable
[expr-plan]: ../../../specs/wired/expressiveness/PLAN.md
[sdl-spec]: ../../../specs/wired/sdl/SPEC.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[flat-issues]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/open-issues.md
[png3]: https://www.w3.org/TR/png-3/
[png-sig]: https://www.w3.org/TR/png-3/#5PNG-file-signature
[png-layout]: https://www.w3.org/TR/png-3/#5Chunk-layout
[png-naming]: https://www.w3.org/TR/png-3/#5Chunk-naming-conventions
[png-crc]: https://www.w3.org/TR/png-3/#5CRC-algorithm
[png-order]: https://www.w3.org/TR/png-3/#5ChunkOrdering
[png-int]: https://www.w3.org/TR/png-3/#7Integers-and-byte-order
[png-fsl]: https://www.w3.org/TR/png-3/#10CompressionFSL
[png-plte]: https://www.w3.org/TR/png-3/#11PLTE
[png-trns]: https://www.w3.org/TR/png-3/#11tRNS
[png-cicp]: https://www.w3.org/TR/png-3/#cICP-chunk
[png-actl]: https://www.w3.org/TR/png-3/#acTL-chunk
[png-seq]: https://www.w3.org/TR/png-3/#4Concepts.APNGSequence
[png-errcheck]: https://www.w3.org/TR/png-3/#13Decoders.Errors
[qoi]: https://qoiformat.org/qoi-specification.pdf
[avif-repo]: https://github.com/AOMediaCodec/libavif/tree/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7
[avif-boxheader]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/stream.c#L248-L295
[avif-iloc]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L2076-L2204
[avif-ipma]: https://github.com/AOMediaCodec/libavif/blob/9b07a9d7a874b159bb4e14b80a6f08bb469d06f7/src/read.c#L3079-L3245
[mpeg-repo]: https://github.com/MPEGGroup/isobmff/tree/689ac096a8e485385089341785c10271cf0684a8
[mpeg-atom]: https://github.com/MPEGGroup/isobmff/blob/689ac096a8e485385089341785c10271cf0684a8/IsoLib/libisomediafile/src/MP4Atoms.c#L801-L855
[mpeg-fullbox]: https://github.com/MPEGGroup/isobmff/blob/689ac096a8e485385089341785c10271cf0684a8/IsoLib/libisomediafile/src/MP4Atoms.c#L106-L125
[mpeg-iloc-size]: https://github.com/MPEGGroup/isobmff/blob/689ac096a8e485385089341785c10271cf0684a8/IsoLib/libisomediafile/src/ItemLocationAtom.c#L205-L274
[mpeg-ipma]: https://github.com/MPEGGroup/isobmff/blob/689ac096a8e485385089341785c10271cf0684a8/IsoLib/libisomediafile/src/ItemPropertyAssociationAtom.c#L214-L237
[ksy-png]: https://github.com/kaitai-io/kaitai_struct_formats/blob/6739687e6af86bb1326953dc6cef7f8e716c10ec/image/png.ksy
[ksy-png-seq]: https://github.com/kaitai-io/kaitai_struct_formats/blob/6739687e6af86bb1326953dc6cef7f8e716c10ec/image/png.ksy#L96-L115
[ksy-png-crc]: https://github.com/kaitai-io/kaitai_struct_formats/blob/6739687e6af86bb1326953dc6cef7f8e716c10ec/image/png.ksy#L117-L196
[ksy-png-iccp]: https://github.com/kaitai-io/kaitai_struct_formats/blob/6739687e6af86bb1326953dc6cef7f8e716c10ec/image/png.ksy#L404-L411
[ksy-png-trns]: https://github.com/kaitai-io/kaitai_struct_formats/blob/6739687e6af86bb1326953dc6cef7f8e716c10ec/image/png.ksy#L598-L631
[ksy-mov]: https://github.com/kaitai-io/kaitai_struct_formats/blob/6739687e6af86bb1326953dc6cef7f8e716c10ec/media/quicktime_mov.ksy#L18-L54
[ksy-guide-bits]: https://github.com/kaitai-io/kaitai_struct_doc/blob/43db335bbdd80ef3ad0bffa55e58de0b7037490b/user_guide.adoc
[dfdl-checksum]: https://github.com/apache/daffodil/blob/b5892e183284a0cd981d798541d45e0378611473/daffodil-core/src/main/java/org/apache/daffodil/api/layers/ChecksumLayer.java#L23-L72
[dfdl-gzip]: https://github.com/apache/daffodil/blob/b5892e183284a0cd981d798541d45e0378611473/daffodil-core/src/main/java/org/apache/daffodil/layers/runtime1/GZipLayer.java
[wuffs-coro]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/coroutines.md#L23-L50
[wuffs-io]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/io-input-output.md#L76-L86
[wuffs-io-position]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/io-input-output.md#L63-L73
[wuffs-png-chunks]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L232-L303
[wuffs-png-pass]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/png/decode_png.wuffs#L1292-L1394
[wuffs-deflate-bits]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/std/deflate/decode_deflate.wuffs#L67-L70
[wuffs-quirks]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/quirks.md#L60-L65
