# API index

The public symbols of `sparkles:base`, by module.

## `sparkles.base`

Package module re-exporting `buffer`, `custom_float`, `lifetime`, `logger`,
`meta`, `prettyprint`, `source_uri`, `styled_template`, `term_caps`,
`term_color`, `term_style`, `text`, and `unique`.

## `sparkles.base.buffer`

| Symbol                          | Description                                                                                     |
| ------------------------------- | ----------------------------------------------------------------------------------------------- |
| `Buffer!(T, N, storage)`        | The container; `storage` is a set of `Storage` capability bits. Prefer an alias below.          |
| `Storage`                       | `inline` / `heap` / `unique` — the capability bits whose combination is the policy.             |
| `InlineBuffer!(T, N)`           | Never allocates; not an output range — write with `tryWrite`. Plain data, no destructor.        |
| `UniqueBuffer!(T, N)`           | Inline until it spills, then heap; move-only, so the grow path carries no reference count.      |
| `SharedBuffer!(T, N)`           | As `UniqueBuffer`, but copyable: copies share the heap block and clone on the next write.       |
| `HeapBuffer!T`                  | Heap only, no inline array; `clear` keeps its block, since there is nothing to revert to.       |
| `tryWrite(dest, fn)`            | Bounded write into storage someone else owns; returns the written slice, or `null` on overflow. |
| `BoundedSink!T`                 | The bounded output range `tryWrite` hands to `fn`.                                              |
| `checkToString` / `checkWriter` | `@nogc` unit-test helpers for output-range rendering assertions.                                |

`UniqueBuffer` is the default choice: a buffer with a single owner should not
pay for a reference count. Reach for `SharedBuffer` when copies genuinely
happen — see the [buffer spec](../../../specs/base/buffer.md).

## `sparkles.base.custom_float`

| Symbol                                                               | Description                                                                                                                                             |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CustomFloat!fmt`                                                    | A format's interchange bits as a value type: the native types' properties, one-rounding conversion in and exact conversion out, arithmetic in `Native`. |
| `Float16`, `BFloat16`                                                | IEEE binary16 and bfloat16.                                                                                                                             |
| `Float8E5M2`, `Float8E4M3`, `Float6E2M3`, `Float6E3M2`, `Float4E2M1` | The OCP Microscaling element formats; E4M3 has a NaN and no infinity, the FP6/FP4 types neither.                                                        |
| `CustomFloat!(precision, exponentWidth, flags)`                      | Phobos' `std.numeric.CustomFloat` spelling, for the flag combinations a `BinaryFloatFormat` expresses.                                                  |
| `isCustomFloat!T`, `NativeOf!fmt`                                    | The type predicate, and the narrowest native type that holds a format exactly.                                                                          |

Modelled on Phobos' `CustomFloat` without its defects — see the
[CustomFloat spec](../../../specs/base/custom-float.md).

## `sparkles.base.unique`

| Symbol                                   | Description                                                                     |
| ---------------------------------------- | ------------------------------------------------------------------------------- |
| `Unique!(T, Allocator, rootInCollector)` | Move-only sole owner of one heap value (struct, scalar, or class instance).     |
| `makeUnique!T(args)`                     | Allocates and constructs a `T`, returning its owner; an empty owner on refusal. |
| `needsCollectorRoot!(T, Allocator)`      | Whether the block is registered as a collector root by default.                 |
| `isCollectorScanned!Allocator`           | Allocator capability probe (`enum bool collectorScanned` opts in).              |
| `isUniqueTarget!(T, Allocator)`          | Whether the pair is ownable — no interfaces, stateless allocators only.         |

See [Own a heap value without the collector](../how-to/own-heap-values.md).

## `sparkles.base.lifetime`

| Symbol                         | Description                                                             |
| ------------------------------ | ----------------------------------------------------------------------- |
| `recycledInstance!T(args)`     | Reinitialises one thread-local static instance of `T`.                  |
| `recycledErrorInstance!T(...)` | Builds an `Error` subclass in recycled storage for `@nogc` throw paths. |

## `sparkles.base.text`

The package re-exports the modules explicitly listed in `text/package.d`,
including UTF, grapheme, width, wrapping and analysis. The table also lists
specialized modules: import `boundaries`, `line_break`, `bidi`, `transform`,
`normalization`, `casing`, `case_text`, `source_map`, and `unicode_tables`
directly; they are not public package re-exports. `float_conv` is likewise a
direct-import module.

| Module                             | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sparkles.base.text.writers`       | Integer (any radix 2–36), float, duration, byte, hex (`writeHexByte`), escape, and value writers.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `sparkles.base.text.readers`       | Slice-advance parsers (`readInteger` at any radix 2–36, `readUntil`) plus hex predicates `isHexDigit` / `hexNibble`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `sparkles.base.text.cstring`       | NUL-terminated C strings without the GC: `toTempStringz` (owns a buffer for the duration of one call), `stringz` (terminates a buffer that outlives the call), `CString!N` + `toCString`/`tryToCString` (fixed `char[N]`, borrow checked by `-dip1000`), `CStr` + `cstr`/`fromStringz`/`fromStringzSlice` (a borrowed C string), `writeStringz` (append a terminator to a writer).                                                                                                                                                                                                                                   |
| `sparkles.base.text.base_codecs`   | RFC 4648 Base16/32/64 and relatives, driven by an `Alphabet` value — see [Base codecs](./base-codecs.md).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `sparkles.base.text.percent`       | RFC 3986 percent-encoding and `x-www-form-urlencoded` — see [Percent-encoding](./percent-encoding.md).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `sparkles.base.text.enums`         | Enum text helpers such as `StringRepresentation`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `sparkles.base.text.errors`        | `ParseErrorCode`, `ParseError`, and `ParseExpected!T`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `sparkles.base.text.float_conv`    | Exact decimal ⇄ binary floating point for any format — `float`, `double`, and `real` at binary64, x87 or binary128, and the reduced formats binary16, bfloat16, FP8, FP6 and FP4 through `CustomFloat`: correctly-rounded `readDecimalFloat!T` (Clinger, Eisel–Lemire at 64 and 128 bits, a narrowing tier below 53 bits, an exact big-decimal tier), shortest round-trip `shortestDigits`/`writeShortest` (Steele–White) and the Schubfach `formatShortestDouble`, plus `encode`/`decode`/`roundTo` between formats, over `BinaryFloatFormat`, the format as data ([spec](../../../specs/base/text/float-conv.md)). |
| `sparkles.base.text.case_style`    | `CaseStyle` and `convertCase` (camel/pascal/snake/kebab/…).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `sparkles.base.text.html`          | HTML entity escaping.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `sparkles.base.text.ansi`          | ANSI escape-sequence scanning.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `sparkles.base.text.utf`           | Owned UTF-8/16/32 scalar and token decoding/encoding; strict, maximal-subpart replacement, and UTF-8 opaque-byte modes; stateless prefix operations and caller-owned `UtfStream` carry/backpressure.                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `sparkles.base.text.utf8`          | UTF-8 well-formedness: `indexOfInvalidUtf8`, `validateUtf8`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `sparkles.base.text.utf16`         | All nine bounded UTF-8/16/32 conversions and their NUL-terminated `z` variants; `measureConversion`, structured encoding reasons, full validation before publication, and an unchanged destination on failure.                                                                                                                                                                                                                                                                                                                                                                                                       |
| `sparkles.base.text.grapheme`      | Owned Unicode 18.0.0 extended grapheme rules without a scalar-count limit; borrowed cluster ranges and `GraphemeStream` absolute-span events across encoding chunks and output backpressure.                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `sparkles.base.text.width`         | Terminal cell width, field alignment, and truncation.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `sparkles.base.text.wrap`          | Style-aware prose wrapping by terminal cell width.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `sparkles.base.text.boundaries`    | Whole-input owned UAX #29 word and sentence boundaries over UTF tokens, with caller scratch.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `sparkles.base.text.line_break`    | Owned default UAX #14 line-break opportunities; not a wrapping solver.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `sparkles.base.text.bidi`          | Whole-paragraph UAX #9 resolution, followed by line-local levels and logical/visual permutations.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `sparkles.base.text.transform`     | Caller-owned transformed units, exact contributor sets, deletion records and epoch-checked borrowed views.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `sparkles.base.text.normalization` | NFC/NFD/NFKC/NFKD with explicit decomposition and ordering scratch.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `sparkles.base.text.casing`        | Full/contextual casing and simple/full folding with explicit locale and caller arenas.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `sparkles.base.text.case_text`     | Allocating strict root Unicode casing and byte-preserving ASCII casing convenience functions.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `sparkles.base.text.source_map`    | Typed source/transformed coordinates, immutable revision keys, affinity and exact relationships.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `sparkles.base.text.analysis`      | Owned normalization/casing/word pipeline with separate final, intermediate, segment and provenance limits.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

See [Unicode analysis](./unicode-analysis.md) for ownership, capacities and
failure contracts.

### UTF and terminal-text acceleration

Under LDC on x86-64, UTF-8 validation uses bounded SIMD blocks: SSE2 baseline
classification or an AVX2/AVX-512BW nibble-lookup validator. Wide runtime
dispatch requires AVX-512F/BW/VL and OS vector-state support; compaction also
requires VBMI2. LLVM's explicit `evex512` target feature enables ZMM lowering.
Multilingual blocks share
an error reduction across four vectors; ASCII tails resume the ASCII shortcut.
Rejected groups and incomplete tails
fall back to scalar decoding, preserving the first invalid **sequence lead**
offset. Inputs require neither padding nor alignment.

UTF-8/UTF-16 conversion vectorizes validation/sizing and ASCII widening or
narrowing. AVX-512BW/VBMI2 also accelerates non-ASCII emission with register
compaction and exact masked stores; homogeneous two-byte and three-byte
blocks avoid the general surrogate/compaction work where possible.
Entirely ASCII blocks return to widening/narrowing rather than compaction.
Compaction helpers pass vector inputs by reference, keeping their pointer/scalar
call boundary stable between baseline and feature-targeted code on Windows.
The complete preflight still precedes any destination write:
malformed input, embedded NUL in a `z` conversion, and insufficient capacity
leave the destination unchanged. Counts exclude the optional terminator.

`visibleWidth` and whole-cluster measurement use the owned Unicode 18 grapheme
engine and the `terminalKitty` cell policy (revision 1). There is no fixed
scalar-count or byte-count grapheme cap and no compiler-probed segmentation
fallback. Cell advance is a policy applied to a complete cluster, not a sum of
isolated scalar widths. Ambiguous width is narrow; controls and separators have
zero advance. Tabs require contextual expansion by wrapping rather than a
context-free source-map tab stop.

The codec SIMD paths do not define normalization, casing, segmentation or
terminal policy. Other compilers/architectures and CTFE retain owned scalar
codec paths. Historical SIMD measurements describe the measured revision, not
an acceptance result for the new analysis or consumer cutovers.

See [measured comparisons and limits](../../../research/simd-unicode/performance.md)
and the [runnable benchmark matrix](https://github.com/PetarKirov/sparkles/blob/878ee7e3ce1b8586d3dbf08d0132cfe568016ac6/libs/base/bench/utf/README.md).

### Whole-cluster fitting and wrapping

`fitCells` and `truncateField` use the same style-transparent complete-cluster
cell policy. An SGR inside a flag, keycap, or emoji presentation sequence cannot
turn a two-cell cluster into independently fitted one-cell pieces.

`WrapOptions.whitespace` selects preservation, collapse, or
`WhitespaceMode.trimAroundBreak`. Preservation is the default and keeps authored
whitespace on its selected side. Trimming omits only selected line-edge whitespace,
not internal spaces or tabs; source records still permit exact original copying.
Bounded prose boxes and tables choose trimming explicitly.
Omitted leading whitespace does not block the first retained unit's overflow
policy, even at bounded width zero. Under `graphemeEmergency`, an overwide
unprotected cluster is emitted alone; only a protected no-break unit may remain
whole and overfull. `overflowUnit` instead retains the complete policy unit.

Indentation uses the same explicit tab stops as paragraph content. A tab in
`firstIndent`, `indent`, or a geometry-specific indent advances from that line's
`startColumn`; it is not rejected or measured as a fixed-width character.

Single-plan exact search discards a dominated prefix only when its complete
future state agrees: source/continuation, line counts, provider and geometry
state, fitness, flagged-break state, and geometry alternative. Equal costs use
the same full-prefix tie order as final ranking. Ranked-alternative operations
retain distinct prefixes and their exhaustive/more status.

Default greedy cell wrapping skips a remaining endpoint tail when the owned
provider proves it cannot contain another fitting candidate and a fitting choice
already exists. It can also stop with only an overfull choice, or no choice yet,
when the provider additionally proves that neither the current nor any later
endpoint can legally overflow. That stronger certificate requires more than one
retained body cluster and exhaustion of the first content unit's overflow
opportunity; the legal whole-unit endpoint and farthest single-cluster endpoint
remain eligible. Owned-cell streams admit these bounds for preserving, collapsed
and break-trimmed whitespace, including contextual tabs and fixed indentation.
Soft-hyphen streams remain uncertified because replacing a discretionary hyphen
can reduce a later extent. Arbitrary `selectionMeasure` callbacks remain
exhaustive; a deterministic target can explicitly declare
`selectionMeasureMonotone` for non-decreasing realized prefixes. Balanced and
ranked-alternative searches retain exact enumeration. The solver caches forced
bounds once and binary-searches each start; byte-work bounds use cluster prefixes,
and emergency unit extents reuse identical projections for owned cells or a
certified target, keyed by column, indent and indent brush.

`CellStyleSnapshot.underline` records the full SGR underline variant independently
of attribute bits: none, single, double, curly, dotted or dashed. Owned `4:n`, legacy
`21`, reset and underline-off codes preserve this state across wrapped lines.
`WrapOptions.selectionMeasure` receives both realized fragments and their snapshot
table; selection extents never replace terminal-cell advances in published fragments.

The built-in cell style parser accepts SGR `10` (primary-font selection), including
the common `0;10` reset sequence. Primary-font selection preserves other attributes
and its original source bytes; it needs no extra snapshot state because alternate
fonts are unsupported. SGR `11`–`19` still report `unsupportedCapability` unless the
caller explicitly selects opaque parsing with copy-through continuity.

`byWrappedLine` / `WrappedLines` and `byWrappedChunk` / `WrappedChunks!lineBuffered`
are allocating, eager-rendering adapters with allocation-free forward iteration.
Construction gathers the supplied input and renders its complete selected plan;
there is no ignored buffer-size parameter or `@nogc` construction promise. Box
streaming still pulls one outer source line at a time, then materializes that line's
wrapping before emitting its rows/chunks. For caller-bounded, allocation-free planning
use `tryWrapCells` with `CellWrapScratch` and `WrapPlanStorage`, followed by the
caller-output `tryMaterializeWrap` emitter.

Ranking keeps the full 64-bit ordering keys on 32-bit targets as well. Only
bounded radix digits become array indices; target pointer width does not narrow
costs or change deterministic tie ordering.

`WrappedChunks!false` partitions selected emission at owned UAX #14 opportunities
intersected with emitted grapheme boundaries. It preserves break-segment pacing,
does not reselect lines, and treats formatting as transparent to segmentation.
Mapping expanded tabs coalesces repeated replacement contributors without merging
their distinct painted space clusters.

Hyphenation resources are validated borrowed tables. Validation, parsing, and
matching publish into their first `ref` argument, return `void`, and report status
through an explicit `ref HyphenationResult`:

- `validateHyphenationResource(published, tables, visits, work, result)`;
- `parseHyphenationResource(published, destination, encoded, staging, visits, work, result)`;
- `matchHyphenation(output, resource, lookup, options, scratch, work, result)`.

A parsed resource borrows both immutable encoded metadata/fragment bytes and its
numeric destination storage. Keep both alive and unchanged. Numeric parser staging
and `HyphenationCandidateDraft` matcher scratch retain no borrowed fragments and
can be released after publication; the published resource/candidates cannot outlive
their borrowed inputs. No compatibility status-return overload remains.

## `sparkles.base.text.property_path`

Import this module explicitly for syntax-only runtime property addresses.
The property tree uses the same parser and emitters; resolving an address against
a subject remains the consumer's responsibility.

| Symbol                          | Description                                                                                                                                                                                        |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PathSeg`                       | Owned parsed segment: `name`, positional `index`, or stable `key`, with `isIndex`, `isKey`, and `isQuoted` discriminators.                                                                         |
| `parsePath(path, out segments)` | Parse the empty root, ASCII identifier members, quoted names, `[index]`, and `[#key]`. Reject malformed continuations, unsupported escapes, and numeric overflow; failure leaves `segments` empty. |
| `childPath(parent, member)`     | Append a member name, using a bare identifier when possible and a quoted name otherwise.                                                                                                           |
| `keyPath(parent, key)`          | Append an always-quoted map key, including identifier-shaped keys: `keyPath("tools", "build")` returns `tools["build"]`.                                                                           |
| `elementPath(parent, index)`    | Append a positional index.                                                                                                                                                                         |
| `keyedPath(parent, key)`        | Append a stable `ulong` identity, distinct from a map key.                                                                                                                                         |
| `parentPath(path)`              | Remove the final segment and canonicalize numeric spelling without losing quoting. A root segment or malformed path returns `""`.                                                                  |

Quoted names escape only `"` and `\` as `\"` and `\\`; other bytes pass through
unchanged. Parsing owns each name independently of the input. These allocating
APIs are `@safe pure nothrow`, not `@nogc`.

## `sparkles.base.term_style`

| Symbol                      | Description                                                                                                   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `Style`                     | ANSI foreground, background, and attribute `[open, close]` code table.                                        |
| `TermStyle`                 | Resolved style: `fg`/`bg`/`underlineColor`, `attrs`, `underline`.                                             |
| `TextAttr`                  | Attribute bitflag struct (bold/dim/italic/strikethrough/inverse/hidden) with typed `\|`/`&`/`~` and `.has()`. |
| `UnderlineStyle`            | Underline shape: none/single/double\_/curly/dotted/dashed.                                                    |
| `writeStyleTransition`      | Differential ANSI encoder: minimal merged `ESC[…m` diff between two `TermStyle`s at a `ColorDepth`.           |
| `stylize`                   | Wrap text in one ANSI style.                                                                                  |
| `stylizedTextBuilder`       | CTFE-friendly chained styling builder.                                                                        |
| `styleName` / `styleSample` | Style names and sample strings.                                                                               |

## `sparkles.base.term_color`

| Symbol                                | Description                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------- |
| `Color`                               | Four-case color: `unset` / `default_` / `palette` / `rgb`.                      |
| `RgbColor`                            | 24-bit RGB triple.                                                              |
| `ColorChannel`                        | SGR channel: `foreground` (38/39) / `background` (48/49) / `underline` (58/59). |
| `writeSgrColor`                       | Emit the SGR color parameters for a `Color` on a channel, depth-folded.         |
| `parseHexColor`                       | Parse `#RGB`/`#RRGGBB`/`#RRGGBBAA` (bat alpha convention) → `Color`.            |
| `ansi256FromRgb` / `ansi16FromRgb`    | Fold an RGB value to the nearest 256-/16-palette index.                         |
| `xterm256ToRgb`                       | The RGB behind an xterm-256 palette index.                                      |
| `ColorDepth`                          | Terminal color tiers: `none` / `ansi16` / `ansi256` / `trueColor`.              |
| `classifyColorDepth(colorterm, term)` | Pure, CTFE-able tier classifier over `$COLORTERM`/`$TERM` values.               |
| `detectColorDepth()`                  | Environment-reading wrapper over `classifyColorDepth`.                          |

## `sparkles.base.styled_template`

| Symbol          | Description                                                           |
| --------------- | --------------------------------------------------------------------- |
| `writeStyled`   | Writes styled IES to an output range (optional leading `ColorDepth`). |
| `styledText`    | Allocating styled string conversion (optional leading `ColorDepth`).  |
| `plainText`     | Allocating conversion with style markup stripped.                     |
| `styledWrite*`  | stdout/stderr helpers for styled IES (optional leading `ColorDepth`). |
| `styleFromName` | Runtime lookup for style names used by the parser.                    |

## `sparkles.base.logger`

| Symbol                                                          | Description                                                      |
| --------------------------------------------------------------- | ---------------------------------------------------------------- |
| `CoreLogger`                                                    | `std.logger.Logger` base class with a Sparkles `@nogc` log path. |
| `CoreLogEntry`                                                  | Metadata captured for Sparkles log calls.                        |
| `DeltaTimeLogger`                                               | stderr logger with wall-clock and monotonic delta prefixes.      |
| `sharedCoreLog`                                                 | Atomic process-wide Sparkles logger.                             |
| `coreGlobalLogLevel`                                            | Atomic process-wide Sparkles log-level filter.                   |
| `CoreFatalHandler` / `coreFatalHandler`                         | Fatal policy hook and global accessor.                           |
| `throwingFatalHandler`                                          | Throws recycled `FatalLogError`.                                 |
| `assertingFatalHandler`                                         | Fails with `assert(0, message)`.                                 |
| `abortingFatalHandler`                                          | Calls `abort()`.                                                 |
| `log`, `trace`, `info`, `warning`, `error`, `critical`, `fatal` | Styled IES logging wrappers.                                     |
| `initLogger`                                                    | Installs `DeltaTimeLogger` for Phobos and Sparkles globals.      |

## `sparkles.base.prettyprint`

| Symbol               | Description                                                       |
| -------------------- | ----------------------------------------------------------------- |
| `PrettyPrintOptions` | Configuration for structural indentation and syntax highlighting. |
| `prettyPrint`        | Pretty-prints any D value to a writer or returns a string.        |

## `sparkles.base.source_uri`

| Symbol              | Description                                                       |
| ------------------- | ----------------------------------------------------------------- |
| `resolveSourcePath` | Resolves relative source path to absolute path.                   |
| `FileUriHook`       | Default hook that formats source locations as `file://` URIs.     |
| `SchemeHook`        | Hook that formats source locations using custom editor schemes.   |
| `EditorDetectHook`  | Runtime detector using `$VISUAL`/`$EDITOR` environment variables. |
