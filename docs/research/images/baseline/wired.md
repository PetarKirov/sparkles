# Sparkles baseline: wired and binary description formats

What `sparkles:wired` ships, what its unmerged Flat draft would add, and what the byte-level code already in `sparkles:font` and the toolkit does today, measured against what image and video container and codec headers need.

| Field          | Value                                                                                                                                                                                                                                                                                                                                                                                               |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Packages       | `sparkles:wired` (`libs/wired`), `sparkles:font` (`libs/font`), the PNG codec of `sparkles:ui` (`libs/ui/src/sparkles/ui/png.d`), `sparkles:base` (hashing, buffers)                                                                                                                                                                                                                                |
| Specs read     | [wired base][wired-spec], [wired plan][wired-plan], [wired open issues][wired-issues], [expressiveness][expr-spec] (+ [plan][expr-plan]), [SDL][sdl-spec], [bench baseline][wired-bench], [font spec][font-spec], [font parsing][font-parsing], [font decisions][font-decisions], the Flat draft ([spec][flat], [plan][flat-plan], [open issues][flat-issues]), [binary-formats research][bf-index] |
| Status summary | wired base, JSON, SDL and the schema layer are shipped. `@WireCheck` is shipped. The Flat binary format is a draft on an unmerged branch with no code anywhere. No bit-level, streaming, suspendable or checksum facility exists in wired, shipped or drafted.                                                                                                                                      |
| Last reviewed  | October 27, 2026                                                                                                                                                                                                                                                                                                                                                                                    |

> [!NOTE]
> This is a baseline for a later design, not a design. Statements about the repo come from files read on branch `feat/images` (HEAD `483c3676c`). The Flat draft was read with `git show` at the pinned revision `8a454ce151c23b3608467cf8e19821678583ecb3` of `origin/docs/wired-flat`; its line numbers below refer to that revision. Quotes join wrapped lines and drop Markdown emphasis and code ticks. Assessments of image formats against Flat are labelled as such: they are reasoning from the draft's text, not tests.

## What exists today

The four statuses are kept apart. Nothing under "specified", "draft" or "planned" is code.

### Shipped (code on this branch)

**wired core and text formats.** `libs/wired/src/sparkles/wired/` holds `policy.d` (the `@Wire*` attributes and resolvers), `schema.d` (`wireSchemaOf!(F, T)`, `WireSchema`, `SchemaNode`, `NodeKind`), `walk.d` (a format-neutral cursor, `FixedWireErrors`), `json/` (native reader, document, writer, codec), `sdl/` (lexer, reader, writer, codec) and `config/`. A format is a marker type (`struct Json {}`); the base spec's §3 says "anyone, including a third-party package, may define one". The package is 29,824 lines of D in 35 files (`wc -l`).

**The schema vocabulary is text-shaped.** `NodeKind` is `scalar`, `enumeration`, `aggregate`, `unionType`, `sequence`, `staticArray`, `map`, `nullAware`, `converted`, `passthrough`, `reference`. `SchemaNode` carries `scalarBits`, `staticLength`, `name`, a resolved `PolicySnapshot` and a range of `SchemaAnnotation`, which is a pair of strings (`typeName`, `value`). It has no byte offset, byte size, alignment or byte order. The Flat draft's own spike confirms the consequence: "The schema has no offsets or sizes, and it preserves unrecognized attributes only as strings".

**JSON reader.** `parseJsonDocument` takes `scope const(char)[] text`, copies it ("the reader takes its own padded copy"), builds an arena document and returns a result with `hasValue`/`hasError`. It enforces `maxDepth = 1024` (`JsonReadOptions`, `json/reader.d`). It is a whole-buffer, one-shot parser: no incremental or resumable entry point exists in `json/reader.d` or `sdl/reader.d` (not verified beyond the signatures and a grep for `stream`, `resum`, `suspend`). Throughput on the twitter corpus is recorded in the [plan][wired-plan] as parse 1,732 MB/s and decode 1,481 MB/s against yyjson at 3,853 and 3,406 (M15+ entry; the exit gate is within 10%).

**Checks and error accumulation.** `@WireCheck`, `isBetween` and `isOneOf` are in `policy.d`, and the JSON and SDL codecs call `wireCheckFailures` (`json/codec.d:927-937`, `sdl/codec.d:1726`). `wireCheckFailures` builds a `WireCheckFailure[]` by appending (`failures ~=`), so it allocates and cannot be `@nogc`. `FixedWireErrors!(Error, capacity)` in `walk.d` is a fixed-capacity sink with an overflow marker. The [expressiveness plan][expr-plan] table lists JSON error-sink overloads as still open.

**Byte-level reading in `sparkles:font`** (accepted spec, shipped code). `libs/font/src/sparkles/font/bytes.d` has `fits`, `slice`, `be16`, `bes16`, `be24`, `be32`, `bes32` (all big-endian, no little-endian reader), each `@safe pure nothrow @nogc`, with `in (fits(...))` contracts that restate a check the caller made first. `errors.d` has `FontError` (kind, table tag, absolute offset, table-relative offset, limit, needed), `FontErrorKind`, `FontLimit`, and `alias FontResult(T) = Expected!(T, FontError, NoGcHook)`. `tables.d` reads `Head` and `Hhea` by hand with explicit offsets (`be16(d, 0), ... bes16(d, 52)`). `variations.d` has a hand-written `ItemVariationStore` that records a failure in a field instead of returning it. `libs/font/dub.sdl` depends on `sparkles:base` and `expected`, not on wired.

**Two PNG decoders, neither using wired.**

- `libs/font/src/sparkles/font/png.d`: `pngHeader`, `decodePng` into caller-owned premultiplied RGBA; 8-bit greyscale, greyscale+alpha, RGB, RGBA, indexed 1/2/4/8; all five filters; `tRNS`; interlaced and 16-bit refused as `unsupportedVersion`; "Chunk CRCs are not checked; the zlib stream's own Adler-32 checksum is"; inflates through Phobos `etc.c.zlib` with a caller-supplied scratch of `pngZlibScratch` (48 KiB); errors are `FontResult`.
- `libs/ui/src/sparkles/ui/png.d`: "the toolkit's one PNG codec"; `pngHeader`, `decodePngInto` (returns `bool`), `decodePng` (returns a GC `ubyte[]`), `encodePng`; every colour type, 1 to 16 bits, Adam7; chunk checksums not checked; `maxPngPixels = 1UL << 26`; `@safe nothrow` but not `@nogc`.

**Hashing.** `libs/base/src/sparkles/base/hash/blake3.d` is a BLAKE3 with a streaming `Blake3` hasher, "Nothing allocates", and portable plus SIMD backends. It exists on this branch, so the Flat draft's [O2][flat-issues] statement that "a BLAKE3 implementation for `sparkles:base` is separate work" is out of date on the branch (the draft predates it or means a different scope: not verified).

### Specified (accepted spec text, no or partial code)

- [wired base spec][wired-spec], `status: accepted`: format concept (§3), policy lattice (§5), errors (§9), native JSON engine (§11). Implemented.
- [Expressiveness spec][expr-spec] (E-series): reified schema (§2), unions (§3), presence (§5), converters and checks (§6), accumulation and context (§7). Per the [delivery table][expr-plan], E3, E4, E6, E7 and E8 are partially delivered; "No milestone above is closed by them". No front-matter status line was read in this file or in the [SDL spec][sdl-spec].
- [Font spec][font-spec] and [parsing][font-parsing], `status: accepted`: `FTB2`, `FTB3`, `FTP14` to `FTP19`, `FTR7`. The font parsing rules are the closest thing to a shipped hostile-input contract for binary data; the Flat draft cites them (`FTP14`, `FTP15`).
- Reserved but unspecified: sibling-field access during decode (expressiveness §7.2, E9 "specified before implementation as part of the `Cli` format design").

### Draft / unmerged

- Branch `origin/docs/wired-flat` at `8a454ce151c23b3608467cf8e19821678583ecb3`: `docs/specs/wired/flat/{SPEC,PLAN,open-issues}.md`, all `status: draft`, `reviewed: 2026-10-16`. `git ls-tree` shows these three files exist only there; the worktree has no `docs/specs/wired/flat/`.
- SPEC: requirements `WFL1` to `WFL56`. Its own table (§10) lists every group with status `planned`. PLAN: FL0 "in progress" (specification review and the O10 spike), FL1 to FL4 `planned`.
- Evidence the draft itself records: an adversarial review (3 blockers, 10 major, 7 minor defects, all dispositioned) and the O10 spike (2026-10-17), an out-of-repo single-file walker that showed `WFL2` feasible on LDC 1.42.0 and DMD 2.112.1. The spike covered neither `Offset` targets, `FlatTagged` nor recursion.
- The [binary-formats research][bf-comparison] is a separate, merged catalog that critiques the draft (its delta table, §9). It is research, not a spec amendment.

### Planned only

- Flat implementation FL1 to FL4 (`sparkles.wired.flat.*` modules in the draft's §2.3 are "proposed"). First consumer: FL4 of the Flat PLAN, a catalog and atlas cache built by Nix and read in place on Android and Linux, which targets the font startup slice (`docs/specs/font/PLAN.md`, "MS Startup slice", status `planned`; that plan does not itself mention Flat).
- The Flat draft's byte source ([O1][flat-issues]): a mapped-file and Android-asset handle in `sparkles:base`. I found no such source in `libs/base/src/sparkles/base` (a grep for `mmap` finds only comments in `buffer.d` and a test). The draft says it needs its own specification in `sparkles:base`.
- Moving `sparkles:font` onto Flat descriptions: excluded from the Flat plan; it needs its own milestone in the font plan.
- Nothing I read plans: bit-granular reads, streaming or suspendable decode, checksums over byte ranges, runtime byte order, 64-bit offsets, or any image or video description. The draft's O9 excludes the first two explicitly.

## Contracts that constrain image and video work

Quotes are verbatim from the cited file at the cited line (Flat lines are in the pinned revision). The first block is draft, the second accepted.

### Flat draft (not shipped; binding only if adopted)

| ID      | Why it matters to image work                                                       | Quote                                                                                                                                                                                                                      | Source             |
| ------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| `WFL5`  | Byte order is compile-time: no runtime selection (TIFF `II`/`MM`).                 | "A leaf with no resolved byte order must fail the proof."                                                                                                                                                                  | SPEC.md:264        |
| `WFL9`  | The borrowed-input rule is what a mapped file to decoder to GPU upload path needs. | "No operation may copy the input, keep a reference to it beyond the returned values, free it, or perform I/O."                                                                                                             | SPEC.md:328        |
| `WFL11` | The bounds rule every container header reader needs.                               | "Before reading a leaf, slicing an array, or following an offset, a view must establish that the whole range lies in the region, with the arithmetic done in 64-bit integers or overflow-checked."                         | SPEC.md:346        |
| `WFL12` | No assertion on data; a codec must meet the same bar.                              | "No value in the input may cause an assertion failure, a RangeError, an exception, a call to a contract-violation handler or undefined behaviour."                                                                         | SPEC.md:354        |
| `WFL14` | Bounds the cost of a read; pixel loops are outside.                                | "No other read may loop or recurse over data; eager validation is bounded by WFL24."                                                                                                                                       | SPEC.md:364        |
| `WFL19` | Invalid `bool`/`enum` bit patterns never become values.                            | "Reading a bool leaf whose byte is neither 0 nor 1, or an enum leaf whose value is not a member, must produce invalidValue with the raw value."                                                                            | SPEC.md:423        |
| `WFL20` | `flatDecode` yields empty dynamic members, so a check cannot see payload bytes.    | "Dynamic members of the returned value are empty, as in any T."                                                                                                                                                            | SPEC.md:432        |
| `WFL21` | Result type is `Expected` with `NoGcHook`: the repo rule.                          | "Every fallible read must return FlatResult!X, an alias of Expected!(X, FlatError, NoGcHook), and must not throw."                                                                                                         | SPEC.md:437        |
| `WFL23` | Validation is optional and complete, with one stated exception.                    | "After a successful validation of unchanged bytes, no read of a view of the same root may return an error, except indexOutOfRange for a caller's argument."                                                                | SPEC.md:480        |
| `WFL24` | The only budget in the draft is traversal bytes and depth.                         | "Validation must charge each record, array element and string it visits max(extent, 1) bytes against FlatLimits.traversalBytes, and track the number of offsets followed on the current path against FlatLimits.maxDepth." | SPEC.md:488        |
| `WFL27` | The only sub-byte facility is a range inside one integer leaf.                     | "@FlatBits!(name, shift, width) on an unsigned integer leaf must define a derived value name of the leaf's type, equal to the width bits of the leaf starting at bit shift."                                               | SPEC.md:532        |
| `WFL28` | Cross-field checks run on the decoded fixed part.                                  | "On Flat, a check receives the value flatDecode produces and runs when a view opens"                                                                                                                                       | SPEC.md:539        |
| `WFL33` | Sequential, self-sized elements (chunk and box streams).                           | "An array whose element sizes depend on each element's own bytes is sequential: it must expose a forward range whose popFront costs the extent of one element, and indexing must cost at most linear time in the index."   | SPEC.md:584        |
| `WFL37` | Version- and flag-dependent tails (ISOBMFF large size, versioned boxes).           | "Every conditional field must follow the fixed part."                                                                                                                                                                      | SPEC.md:626        |
| §5.3    | Offset widths stop at 32 bits.                                                     | "a leaf whose value is an unsigned integer of width W (ubyte, ushort, FlatU24, uint)"                                                                                                                                      | SPEC.md:596-597    |
| `WFL45` | Arena-only alignment ceiling; pixel planes want more.                              | "Every record reachable from a root carrying @FlatArena must have a canonical alignment of at most 4, or the proof fails."                                                                                                 | SPEC.md:906        |
| `WFL56` | Error size and allocation budget.                                                  | "A FlatError must not exceed 160 bytes, and building or rendering one must not allocate from the garbage collector."                                                                                                       | SPEC.md:978        |
| Scope   | Bit packing and stream codecs are out.                                             | "It does not encode values whose size lives only in a stream, such as D slices behind a length prefix in the manner of cerealed, and it does not pack fields at bit granularity across byte boundaries."                   | SPEC.md:73-75      |
| `O9`    | The exclusion covers every milestone.                                              | "Both are excluded from every milestone; a consumer that needs either brings a separate design."                                                                                                                           | open-issues.md, O9 |
| `O3`    | Stale against main: `@WireCheck` is shipped.                                       | "Cross-field checks reuse @WireCheck from the expressiveness specification, which has no implementation."                                                                                                                  | open-issues.md, O3 |

### Accepted specs (binding now)

| ID                  | Why it matters to image work                                                                    | Quote                                                                                                                   | Source                                        |
| ------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `FTB2`              | The bar any image header reader will be held to in this repo.                                   | "Malformed input must not reach an assert, a contract precondition, an array bounds check or an integer-overflow trap." | `docs/specs/font/SPEC.md:132`                 |
| `FTB3`              | Fixed, named, per-operation limits are the shipped budget model.                                | "Every operation must have a documented worst-case cost in terms of input sizes and these fixed limits"                 | `docs/specs/font/SPEC.md:137`                 |
| `FTP17`             | Spec says accessors "return an error"; the code asserts and relies on a prior `fits` (see G10). | "All reads must go through bounds-checked big-endian accessors that return an error rather than read past the slice."   | `docs/specs/font/parsing.md:90`               |
| wired §11.3         | The shipped parser copies its input; a Flat-style view does not.                                | "the reader takes its own padded copy (which then becomes the string pool)."                                            | `docs/specs/wired/SPEC.md:1197`               |
| expressiveness §7.2 | A length field cannot steer a later field's decode in the generic walk.                         | "Sibling field access during decode is deliberately not in this revision"                                               | `docs/specs/wired/expressiveness/SPEC.md:453` |

Repo-wide standing rules (from `AGENTS.md`) that bind any new image code: `@safe pure nothrow @nogc` for non-templates and inferred attributes for templates, `Expected` for errors, writers over strings, `@trusted` only around one operation, dip1000 on, no package-local copies of shared infrastructure, tests in feature modules, `--better-c`/`--wasm` extraction where used.

## Capability table

Status values: **shipped** (code on this branch), **specified** (accepted spec text), **draft** (unmerged branch), **planned** (named in a plan only), **absent** (nothing read).

| Capability                                           | Where                                         | Status              | Evidence                                                                    |
| ---------------------------------------------------- | --------------------------------------------- | ------------------- | --------------------------------------------------------------------------- |
| Compile-time schema from D types                     | `libs/wired/src/sparkles/wired/schema.d`      | shipped             | `wireSchemaOf`, `NodeKind`, `SchemaNode`; no offset/size/endian fields      |
| Format-marker concept, policy lattice                | `policy.d`, wired SPEC §3, §5                 | shipped             | `AnyFormat`, `@Wire*` resolvers                                             |
| Text formats (JSON, SDL)                             | `json/`, `sdl/`                               | shipped             | reader, writer, codecs, conformance suites                                  |
| Whole-buffer parse with depth limit                  | `json/reader.d`                               | shipped             | `maxDepth = 1024`, copies input                                             |
| `@WireCheck` cross-field checks                      | `policy.d`, `json/codec.d`, `sdl/codec.d`     | shipped             | `wireCheckFailures` (allocating)                                            |
| Fixed-capacity error sink                            | `walk.d`                                      | shipped             | `FixedWireErrors`                                                           |
| Binary wire format on `wireSchemaOf`                 | none on main                                  | absent              | no `sparkles.wired.flat` under `libs/wired/src`                             |
| Bounds-checked big-endian reads                      | `libs/font/src/sparkles/font/bytes.d`         | shipped             | `fits`, `be16`..`bes32`; no LE reader                                       |
| Located, limit-naming error value                    | `libs/font/src/sparkles/font/errors.d`        | shipped             | `FontError`, `FontLimit`, `FontResult`                                      |
| Fixed per-operation limits                           | font SPEC `FTB3`, `errors.d` `fontLimitValue` | shipped / specified | 11 named limits, e.g. `compositeDepth` 8, `cffOperations` 65,536            |
| Hand-written OpenType table readers                  | `font/tables.d`, `variations.d`, `coverage.d` | shipped             | explicit offsets, no description                                            |
| PNG decode, strict subset, caller storage            | `font/png.d`                                  | shipped             | `decodePng`, `pngZlibScratch`                                               |
| PNG decode/encode, full, GC                          | `ui/png.d`                                    | shipped             | `decodePngInto`, `encodePng`, `maxPngPixels`                                |
| CRC or Adler verification of image chunks            | both PNG modules                              | absent              | "Chunk CRCs are not checked" (font), "chunk checksums are not checked" (ui) |
| BLAKE3 hashing (streamed)                            | `libs/base/src/sparkles/base/hash/blake3.d`   | shipped             | `Blake3` output range                                                       |
| Layout proof, `flatLayoutOf`, digest                 | Flat SPEC §3, `WFL3`-`WFL8`, `WFL41`          | draft               | no code; spike only                                                         |
| In-place `native` view, accessors                    | Flat `WFL15`-`WFL17`, `WFL52`                 | draft               | no code                                                                     |
| Counted, byte-length, rest arrays                    | Flat `WFL29`-`WFL33`                          | draft               | no code                                                                     |
| Offsets with record/ancestor/region bases, null      | Flat `WFL34`-`WFL36`                          | draft               | 8/16/24/32-bit only                                                         |
| Conditional fields, tagged unions, parameters        | Flat `WFL37`-`WFL40`                          | draft               | OpenType `OS/2`, Coverage, `ItemVariationData` examples                     |
| Bit ranges inside one integer leaf                   | Flat `WFL27`                                  | draft               | `@FlatBits`                                                                 |
| Eager validation with traversal budget               | Flat `WFL23`-`WFL24`                          | draft               | provisional HarfBuzz-derived defaults (O7)                                  |
| Arena header, builder, layout pins                   | Flat `WFL43`-`WFL50`, `WFL54`                 | draft               | planned FL3; alignment ceiling 4                                            |
| Compact error path (160 B, no GC)                    | Flat `WFL51`, `WFL56`                         | draft               | no code                                                                     |
| Mapped-file / asset byte source                      | Flat O1; `sparkles:base`                      | planned             | none found in `libs/base/src`                                               |
| Bit-granular reader / writer                         | anywhere                                      | absent              | grep for `bitreader`, `bitstream`, `readBits` in `libs`, `apps`: no match   |
| Suspendable / incremental decode, short-read status  | anywhere                                      | absent              | no mention in Flat SPEC/PLAN/issues beyond O9's exclusion                   |
| Checksum over a byte range declared in a description | anywhere                                      | absent              | `checksumAdjustment` appears only as a plain `uint` in Flat's `Head`        |
| Runtime byte order, 64-bit offsets, varints          | anywhere                                      | absent              | `WFL5`; §5.3 offset list                                                    |

## Gaps and tensions

Each item names the catalog question it informs. "Certain" means the draft's text excludes it or nothing in the repo provides it; "assessment" means reasoning from text.

**G1. Wired main cannot describe binary data at all (certain). Q4, Q9.** The only shipped backends are text. The reified schema has no offset, size, alignment or byte order, and keeps foreign attributes as strings, so a binary backend must re-read the D declaration beside the schema, as the Flat spike did. The draft's `WFL2` ("Flat must not keep a second description of T that is not indexed by schema nodes") is feasible per the spike but unbuilt.

**G2. No bit-level facility (certain). Q4.** `WFL27` names bit ranges inside one leaf of at most 64 bits. Entropy-coded payloads (DEFLATE, Huffman, arithmetic and range coders, CABAC-style bitstreams, JPEG scan data) need a bit reader with refill and a need-more-input outcome. The draft excludes it ("it does not pack fields at bit granularity across byte boundaries"; O9). An image codec must bring a separate design, and that design is not in any plan.

**G3. No suspendable or incremental decode and no Wuffs-style status vocabulary (certain). Q4, Q6.** `FlatErrorKind` has `truncated`, which is terminal ("A range starts at or before the region's end but does not fit"). There is no short-read or "suspended" status, no resumable state, and no notion of feeding more bytes. The wired JSON reader is one-shot over a full buffer. A streaming file-to-GPU path, progressive images, and video demuxing all need this. How it composes with `Expected`-based `nothrow @nogc` results is open.

**G4. Checksums over ranges cannot be declared (certain for Flat as drafted). Q4, Q8.** `WFL28` checks see "the value flatDecode produces", and `WFL20` says its dynamic members "are empty", so a check cannot see a chunk payload to verify a CRC. Both shipped PNG decoders skip chunk CRCs, which is a conformance decision (stb_image parity in `ui/png.d`) that image work will have to revisit. BLAKE3 exists in base; CRC32 and Adler-32 are reached through Phobos (`std.digest.crc` in `ui/png.d`, zlib in both).

**G5. Runtime byte order and 64-bit/variable-width offsets are not expressible (certain). Q4.** `WFL5` fixes endianness at compile time (TIFF's header byte decides it at runtime; an assessment is that two instantiations of one description and a dispatch would work). Offsets are 8, 16, 24 or 32 bits (§5.3): no 64-bit offsets (BigTIFF, `co64`), no varint widths (EBML, LEB128). `FlatSpan` is two `uint` fields (4 GiB).

**G6. Length-prefixed, self-sized sequences are specified but the cost story is open (assessment). Q4, Q8.** `WFL33` allows sequential arrays whose elements size themselves, which is the shape of PNG chunks, RIFF chunks, ISOBMFF boxes and OBU streams. The [binary-formats comparison][bf-comparison] notes that finding a member after such an array means visiting every earlier element, and asks for "a worked trace" in the draft; none exists. Whether a size field that includes its own header (ISOBMFF) or a size of 1 meaning a 64-bit size follows (needs `@FlatPresentIf` plus a 64-bit leaf) fits is not shown by any acceptance fixture.

**G7. Alignment and layout model is for records, not rasters (tension). Q1.** `WFL45` caps arena alignment at 4; pixel planes want row pitch, 16/32/64-byte alignment for SIMD and often 256-byte pitch for GPU copies (the last is not verified against any file in the repo). A `FlatArray!E` over a uniform leaf can expose `const(E)[]` through `native` only when host-endian, aligned and free of `bool`/`enum`; it has no stride, no N-D shape and no plane concept. Whether to describe pixel buffers with Flat at all is therefore a Q1 decision, not a consequence.

**G8. Budget models differ and none fits pixels (tension). Q4, Q8.** Three exist: Flat's `FlatLimits.traversalBytes` and `maxDepth` (provisional, measured only against fonts: O7), font's fixed `FTB3` table, and `ui/png.d`'s `maxPngPixels`. A decompression-bomb budget bounds output size, which is neither traversal bytes nor depth. The `ui/png.d` approach ("the inflated stream must be exactly as long as the header says") is the only output-size defence on the branch.

**G9. Error types fragment, which collides with the standing no-package-local-copies-of-shared-infra rule (tension). Q4, Q9.** On this branch: `JsonError` (carries a `SharedBuffer!(char, 48)` path), a ParseError family in `sparkles.base.text.errors`, `FontError` (kind, tag, two offsets, limit), the drafted `FlatError` (160 bytes, visit-table paths), and `bool` in `ui/png.d`. A PNG decode in `font/png.d` returns `FontError` with `Tag.init`, which is a font-package type leaking into an image concern.

**G10. Spec/code drift in the byte primitives (certain). Q8.** `FTP17` says accessors "return an error rather than read past the slice"; `bytes.d` implements `be16` and friends with `in (fits(...))` contracts and relies on callers to test `fits` first (the module doc says "whose preconditions only restate a check the caller already made"). That satisfies `WFL12`'s allowance but not `FTP17`'s literal text. Copying `font.bytes` into an image package would copy the drift. Also `bytes.d` is big-endian only; image formats are mostly little-endian.

**G11. Two PNG decoders on one branch (certain). Q8, Q9.** They differ in capabilities (font: no interlace, no 16-bit; ui: all), result style (`Expected` over caller storage vs `bool` and GC arrays), and allocation (48 KiB caller scratch vs GC arrays; both inflate through `etc.c.zlib`, `std.zlib` is only the encoder's `compress`). Both lean on Phobos zlib, and `ui/png.d` has a differential test against PngSuite via `sparkles.ui_raylib.png_oracle`. This is exactly the duplication the standing rule forbids once an image package exists.

**G12. wired is not an obvious home for betterC/wasm/Android-minimal code (assessment). Q9.** `schema.d` imports `std.json`, `std.datetime.systime` and `std.sumtype`, and wired depends on `optional` and `expected`. I found no `@betterC` or `@wasm` test in `libs/wired` (grep). Flat's `WFL2` ties it to `wireSchemaOf`, so Flat inherits that import closure unless the layout proof stops depending on the schema. Whether image-core needs `--better-c` extraction is a Q9 question; the answer constrains whether it may depend on wired. Conclusion is inference, not a build result.

**G13. The draft has stale or unmeasured premises (certain). Q8.** O3 says `@WireCheck` "has no implementation"; main ships it (G4). O2 treats BLAKE3 as future. O7's budget defaults are HarfBuzz's, "not measured for Flat". `WFL23` has the wrong-variant exception the [comparison][bf-comparison] already asks to narrow. The draft's own independence rule is worth keeping for image work: "A round trip through the builder never stands alone as evidence for a reader requirement" (PLAN.md, "Evidence common to every milestone").

**G14. No byte source, no file-to-GPU story in wired (certain). Q6.** `WFL9` and `WFL10` give a clean borrowed-bytes contract, but the mapped-file source is O1 and unwritten; atomic replace and `SIGBUS` on truncation are called out as outside D-level contracts. Nothing in wired touches `event-horizon`, io_uring, Vulkan upload or texture formats. The alignment a GPU upload needs is stated nowhere I read (not verified).

**G15. Colour, HDR and metadata (assessment). Q5.** wired has no colour type. ICC profiles, EXIF and ISOBMFF item properties are tagged, offset-addressed binary structures of the kind `WFL34`-`WFL39` target, so they are plausible Flat descriptions, but no acceptance set covers them (the draft's set is OpenType only, `WFL42`). Schema metadata UDAs (`@WireDoc` and friends) are listed as open in the [expressiveness plan][expr-plan] (E8).

**G16. Generic algorithms, SIMD, GPU (Q3, Q7): wired contributes only precedent.** The JSON scanner has SWAR/word tricks in `json/scan.d` and the plan defers SIMD ("SIMD is a later iteration"). wired offers no algorithm schedule, no kernel abstraction and no CPU/GPU dispatch; the Flat draft does not touch them. The `WFL52` codegen rule (one load per leaf) is the only performance acceptance gate in the binary area, and it is about field reads.

**G17. Hostile-input evidence exists but is font-shaped (assessment). Q8.** The plan's every-truncation and single-bit-flip mutation corpus under ASan and the independence rule transfer. Image formats add decompression ratio attacks, huge declared dimensions, and state-machine desync, none of which Flat's corpus targets. The font tests use HarfBuzz and FreeType as oracles; an image equivalent (libpng, libjpeg-turbo, Wuffs) has no declared home yet.

## Questions for the design grill

Options and recommendations only; none is decided.

1. **Where do container-header readers come from? (Q4, Q9)**
   - A. Hand-written bounded readers on a shared byte kernel, as `sparkles:font` does today.
   - B. Wait for Flat FL1/FL2 and describe headers declaratively.
   - C. A shared byte and error kernel now (promoted from `font.bytes`, fixing G10), Flat adopted later for fixed-layout headers only.
   - Recommendation: C. It removes the copy risk of G9 and G10 without betting on an unmerged draft.

2. **Who owns bit-level and entropy streams? (Q4)**
   - A. A `sparkles:base` bit reader/writer with refill and a short-read outcome.
   - B. Inside each codec package.
   - C. Widen Flat (reverse O9).
   - Recommendation: A. Flat's value is its closed, in-place model (G2); widening it would undo that.

3. **Suspension model. (Q4, Q6)**
   - A. Wuffs-style: codec state structs return a status (ok, short read, error) and resume.
   - B. Whole-input-at-once with caller-sized chunks, as `FlatView` assumes.
   - C. Drive decode as `event-horizon` effects.
   - Recommendation: A for codecs, B for headers; C is a scheduling layer over A, not a replacement. Needs a status type that coexists with `Expected` (G3).

4. **One error vocabulary or many? (Q4, Q9)**
   - A. Per-package error types with a shared kind enum.
   - B. A shared `base` kind, location and limit struct, size-capped like `WFL56`.
   - C. Reuse `FlatError` as drafted.
   - Recommendation: B. `FlatError` is bound to the Flat visit table and path scheme; font, Flat and image all need kind, offset and named limit (G9).

5. **Budget shape for hostile input. (Q4, Q8)**
   - A. Flat's traversal bytes plus depth.
   - B. Output-size and pixel budgets per codec, in the style of `maxPngPixels`.
   - C. One `Limits` struct carrying both, named in errors as `FTB3` does.
   - Recommendation: C, with defaults measured on an image corpus rather than inherited from HarfBuzz (G8, G13).

6. **What happens to the two PNG decoders? (Q8, Q9)**
   - A. Move `ui/png.d` into the image package and make font a client.
   - B. Keep the strict subset in font beside a new full codec.
   - C. A new codec package; both existing modules become thin adapters.
   - Recommendation: C, decided before any other format lands, with the PngSuite differential test carried over (G11).

7. **Runtime endianness and wide offsets. (Q4)**
   - A. Extend Flat with a runtime-endian view parameter and 64-bit offsets.
   - B. Two instantiations of one description and a dispatcher.
   - C. Hand code for the formats that need it.
   - Recommendation: B for TIFF-like cases; defer A until a second format needs it (G5).

8. **Checksums. (Q4, Q8)**
   - A. A declarative range-checksum attribute in the description.
   - B. A codec pass after structural validation.
   - C. Left to the container verifier.
   - Recommendation: B, because the check must see payload bytes that `WFL20` keeps out of the decoded record (G4). Revisit A after Flat FL2.

9. **Does image-core depend on wired at all? (Q9, Q1)**
   - A. No dependency; formats may depend on it.
   - B. Core depends on the schema layer for metadata.
   - C. Core hosts the Flat-style layout proof.
   - Recommendation: A, given the import closure in G12 and the `--better-c` constraint; confirm with a build.

10. **Are pixel planes Flat arrays? (Q1)**
    - A. Yes, for packed uniform leaves, through `native`.
    - B. No; image views own stride and shape, Flat describes only headers.
    - Recommendation: B. `WFL45` and the lack of stride (G7) make A a poor fit, and the image view type is the Q1 decision.

## Sources

Repo documents:

- Wired: [base spec][wired-spec], [plan][wired-plan], [open issues][wired-issues], [expressiveness spec][expr-spec], [expressiveness plan][expr-plan], [SDL spec][sdl-spec], [bench baseline][wired-bench].
- Flat draft at the pinned revision: [SPEC][flat], [PLAN][flat-plan], [open issues][flat-issues].
- Font: [spec][font-spec], [parsing][font-parsing], [decisions][font-decisions] (`FTX4`), [plan][font-plan].
- Research: [binary-formats index][bf-index], [comparison][bf-comparison], [concepts][bf-concepts], [Kaitai][bf-kaitai], [Construct][bf-construct], [DFDL][bf-dfdl], [SBE][bf-sbe], [FlatBuffers][bf-fb].
- Guidelines: [Writing Research Docs](../../../guidelines/research-docs.md).

Source files read (paths from the repository root):

- `libs/wired/src/sparkles/wired/{package,schema,walk,policy}.d`, `json/{reader,codec,error}.d`, `sdl/{reader,codec}.d`, `libs/wired/dub.sdl`
- `libs/font/src/sparkles/font/{bytes,tables,errors,png,bitmap,variations}.d`, `libs/font/dub.sdl`
- `libs/ui/src/sparkles/ui/png.d`
- `libs/base/src/sparkles/base/hash/blake3.d`
- `AGENTS.md` (standing rules)

Not verified: the SDL spec's status line, the content of `docs/specs/wired/config/`, the Flat PLAN beyond its FL0 to FL4 sections and review table, whether any base module offers a mapped-file source under a name other than `mmap`, and any build or test result (nothing was built or run for this document).

<!-- References -->

[wired-spec]: ../../../specs/wired/SPEC.md
[wired-plan]: ../../../specs/wired/PLAN.md
[wired-issues]: ../../../specs/wired/open-issues.md
[expr-spec]: ../../../specs/wired/expressiveness/SPEC.md
[expr-plan]: ../../../specs/wired/expressiveness/PLAN.md
[sdl-spec]: ../../../specs/wired/sdl/SPEC.md
[wired-bench]: ../../../specs/wired/bench-baseline.md
[font-spec]: ../../../specs/font/SPEC.md
[font-parsing]: ../../../specs/font/parsing.md
[font-decisions]: ../../../specs/font/decisions.md
[font-plan]: ../../../specs/font/PLAN.md
[flat]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/SPEC.md
[flat-plan]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/PLAN.md
[flat-issues]: https://github.com/PetarKirov/sparkles/blob/8a454ce151c23b3608467cf8e19821678583ecb3/docs/specs/wired/flat/open-issues.md
[bf-index]: ../../binary-formats/index.md
[bf-comparison]: ../../binary-formats/comparison.md
[bf-concepts]: ../../binary-formats/concepts.md
[bf-kaitai]: ../../binary-formats/kaitai-struct.md
[bf-construct]: ../../binary-formats/construct.md
[bf-dfdl]: ../../binary-formats/dfdl.md
[bf-sbe]: ../../binary-formats/sbe.md
[bf-fb]: ../../binary-formats/flatbuffers.md
