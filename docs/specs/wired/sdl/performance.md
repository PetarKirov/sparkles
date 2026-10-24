---
status: draft
owner: sparkles:wired
reviewed: 2026-10-24
---

# `sparkles.wired.sdl` — Performance architecture

## Abstract

`sparkles:wired` reads and writes SDL at a cost set by the input's bytes,
not by its line structure or schema size, by building on the same shared
text, buffer and span primitives as its JSON backend. Every optimization is
measured against a committed baseline on pinned recipes, and none may
weaken the backend's source positions, ordering, scalar fidelity, error
structure or round-trip laws.

## Introduction

The SDL backend was built for correctness first; its
[delivery plan](./PLAN.md) leaves optimization to separate, measured work
after S10. Its parser lexes every source twice — once to size the arena,
once to fill it — and maintains a line and a column on every byte. Each span
stores both positions at 32 bytes; a node view carries four slices and an
index. The typed decoder scans a node's children once per field, so a wide
aggregate over a long recipe costs fields × children. And there is no parser
benchmark at all: the only SDL measurement is a scalar-writer workload.

The JSON backend shows what the codebase already knows how to do: the
document owns a padded copy of its input, the hot path works in byte
offsets and computes line and column only when an error is reported, cells
are compact and views small, and the decoder walks members once with
compile-time key dispatch. This page adopts those techniques where SDL's
grammar allows them, and reuses the shared primitives they are built from
rather than growing SDL-local copies.

Out of scope: SIMD structural indexing (JSON does not use one either), and
any change to the accepted language, the semantic tree's contents, or the
typed mapping. The one observable change — how a span stores its position —
is an explicit amendment to the accepted SPEC, stated in
[§3](#3-amendment-to-the-accepted-spec).

## Contract at a glance

| ID   | Obligation                                                                                 |
| ---- | ------------------------------------------------------------------------------------------ |
| SDP1 | A committed benchmark covers parse, typed decode, encode and edit on pinned recipes        |
| SDP2 | Each optimization lands only with before/after numbers that show no regression elsewhere   |
| SDP3 | The document owns its source; spans are byte ranges into it; positions are exact on demand |
| SDP4 | Parsing lexes the source once, and no pointer into the arena is invalidated while it does  |
| SDP5 | Typed decode visits each child and attribute of a node a bounded number of times           |
| SDP6 | Scratch storage uses `sparkles.base.buffer`; arena blocks keep the caller's allocator      |
| SDP7 | No optimization changes a conformance, law, golden, error or position result               |

## 1. Measurement

**SDP1 — Benchmark.** The `wired_bench` runtime harness
(`libs/wired/bench/runtime`) gains SDL rows: `parse`, `decode` (into the
`dub.sdl` schema) and `encode` first, and `edit` (resolve and write one
attribute change) once the editor exists. Datasets are pinned like the JSON
ones, in the harness's Nix data package: a snapshot of the repository's
recipes taken at a named commit, a concatenated large recipe, and a
generated deep and wide document. Each row verifies itself once, untimed,
against a fingerprint committed with the dataset — the hash of the
canonical writer's output for the parsed or round-tripped document — so a
fast wrong answer fails. Results are committed under the harness's
`results/` directory with the machine and toolchain, as the JSON baseline
is. The pinned DUB SDLang parser is measured alongside as an external
reference point, not a target.

**SDP2 — Gate.** An optimization lands with its before/after medians on
every SDL row and on the JSON rows it could affect, using `-b bench`
(assertions live). A regression beyond the observed variation on any row
rejects or reworks the change, and the measured rejection is recorded, as
the plan already does for the scalar-scratch decision.

## 2. Architecture

**SDP3 — Owned source, byte spans, exact positions.** The document copies
its source into its pool, as the JSON document does, so a document is
self-contained: typed decode, error reporting and the
[editor](./editing.md) all read the same bytes. Tokens, cells, scalars and
layout spans store `TextSpan` (`sparkles.base.text.span`) byte ranges into
that copy. While lexing, the parser records the byte offset of every
logical line start (`\n`, `\r`, `\r\n`, U+2028, U+2029), which it finds
anyway; line 1 starts after the byte-order mark, if there is one, because
the lexer counts no column for it. A position is then the line found by
binary search, and the column counted from that line's start exactly as the
lexer counts today: one per UTF-8 sequence, one per invalid byte.

The cells, the source copy and the line table live in one heap block, the
document's **core**, which does not depend on the allocator type and does
not move when the document does. Node and attribute views refer to the core,
so a view — and the typed decoder walking it — can turn any span into a
position, and moving a document never invalidates its views. Errors keep
eager positions, computed when the error is made.

The values must equal today's for every span and every error; the conformance, error and position goldens are the oracle. A
source whose length is `uint.max` bytes or more fails with
`allocationFailed`, since `TextSpan` reserves `uint.max` as its invalid
sentinel.

**SDP4 — One pass, no moving pointers.** The reader lexes once. The
source copy, the source name, names and decoded strings are all slices of
the pool, so the pool is sized once, before lexing: the source length plus
padding, the source name's length, and a decoded region no longer than the
source. That bound holds because every decoding shrinks or copies — escapes
shrink, Base64 shrinks, a zone is a substring, invalid UTF-8 is rejected
rather than replaced, names are copied raw — and an escape-free string or
name may instead slice the source copy directly. The index-addressed cell
arrays (nodes,
values, attributes, children, line starts) start from a cheap bound on the
source length and grow geometrically on the rare overflow; nothing holds a
pointer into them while they can grow. The count-then-fill pass goes.

**SDP5 — Linear typed decode.** For each aggregate, the decoder walks the
node's children and attributes once, dispatching each by its qualified name
through a compile-time table of the schema's names, and fills fields as it
goes; map fields take the unclaimed remainder. Namespace matching, repeated
children and positional values keep their current semantics. _Oracle:_ a
wide-aggregate test counts name comparisons. _Violation:_ a count that grows
as fields × children.

**SDP6 — Shared buffers, caller's allocator.** Single-owner scratch is a
`UniqueBuffer`; a fixed-width scratch retained because a buffer measured
slower keeps its recorded measurement. Arena blocks stay on the document's
allocator parameter, which the editor's re-parse, the allocation-failure
rollback test and `@nogc` callers rely on; they move to
`sparkles.base.buffer` only if the buffer gains allocator support, which is
not part of this work.

**SDP7 — Unchanged results.** Every optimization keeps the conformance
suite, both round-trip laws, the typed goldens, and the error-code and
position goldens green, on every platform CI tests.

## 3. Amendment to the accepted SPEC

S13 changes the accepted [SPEC §4.1](./SPEC.md#41-spans) and
[§7](./SPEC.md#7-errors-and-source-context) in the same commit as the code,
once this page is accepted:

- `SdlSpan` holds a `TextSpan` byte range instead of two eager
  `SdlPosition`s; `SdlDocument` gains `position(offset)` returning the
  `SdlPosition` defined today, and `source()` returning its owned copy.
- `SdlError` keeps its `SdlSpan` and also carries the start and end
  `SdlPosition`s, filled when the error is made, so rendering an error needs
  no document.
- The lexer's `SdlToken` keeps `raw`, and its span becomes a byte range;
  `SdlLexer` gains the same `position(offset)`.
- `SdlNode` and `SdlAttributeView` refer to the document's core (SDP3)
  instead of holding arena slices; their public members are unchanged.

In-repository consumers migrate in the same commit: `dub_recipe.d` (a
configuration's line), the `dub_manifest.d` error-line test, `dub_deps.d`'s
attribute splice (which moves to the editor in S15 anyway), the
`sdl.conformance.publicSurface` test, and the SDL reference and how-to
pages. Error rendering (`SdlError`'s writers) reads the eager positions and
does not change, so error-text goldens and example outputs stay as they
are; the gate re-runs them to prove it.

## 4. Prerequisites in `sparkles:base`

The line-start table is the shared line index
(`sparkles.base.text.lineindex`), extended rather than copied. Today it
splits on `\n` only, reports byte columns, scans its text without keeping
it, and allocates its table on the GC heap. It gains:

- a newline policy: `\n` only (today's behaviour, the default) or the
  logical set above;
- a first-line start, for text after a byte-order mark;
- construction from line starts a caller already found, so the SDL lexer
  records them in its single pass instead of the index rescanning;
- an overload of `lineColAt` that takes the text, and counts columns in
  UTF-8 sequences with one column per invalid byte — the index keeps not
  storing text, so byte columns stay the default;
- `@nogc` storage in a copyable `SharedBuffer`, since callers such as the
  D twoslash analyzer store and reassign an index.

Existing callers keep their results and their copy semantics unchanged; the
index's tests gain every SDL newline form, a byte-order mark, and
invalid-UTF-8 columns.

## 5. Decisions

| Question                 | Choice (proposed)                                                            | Alternative and why not                                                                                                                                |
| ------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Who owns the source      | the document, as in JSON (SDP3)                                              | the caller: decode and editing would need the source passed alongside, and positions could not be computed                                             |
| Where positions live     | byte spans; positions on demand, eager in errors                             | eager everywhere: 24 bytes more per span, and the per-byte position update is the lexer's hottest loop                                                 |
| Span type                | the shared `TextSpan`                                                        | an SDL span with `uint` offsets: a second copy of a primitive base already owns                                                                        |
| Line table               | base's line index, extended (§4), fed by the lexer                           | an SDL-local table: a second copy of a primitive base already owns                                                                                     |
| Arena growth             | pool sized once; cell arrays grow (SDP4)                                     | exact pre-count: doubles lexing, which is what this page removes                                                                                       |
| Allocator                | kept (SDP6)                                                                  | `sparkles.base.buffer` blocks: no allocator parameter, which `@nogc` callers and the editor need                                                       |
| Node views               | a core reference and a cell index, 16 bytes (S13)                            | today's four slices and an index: about 72 bytes, and no way to reach the source or line table; a pointer to the document itself dangles when it moves |
| Node handles for editing | none in the first slice ([editing §8](./editing.md#8-deferred-capabilities)) | generational pool handles: need a heap-backed slot table in base, and no consumer needs them yet                                                       |
