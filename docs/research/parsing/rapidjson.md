# RapidJSON (C++)

The fast C++ JSON standard from _before_ [simdjson][simdjson] — a header-only, self-contained parser/generator offering a dual **SAX** (event) and **DOM** (tree) API, a template-specialized recursive-descent reader, destructive **in-situ** zero-copy parsing, and a pool allocator, with SIMD used only as a _narrow_ optimization (whitespace skipping and string scanning), not as the parsing strategy.

| Field                     | Value                                                                                                      |
| ------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Language                  | C++ (header-only, no STL/BOOST dependency)                                                                 |
| License                   | MIT (source); `bin/jsonchecker/` alone is under the JSON license                                           |
| Repository                | [`Tencent/rapidjson`][repo]                                                                                |
| Documentation             | [rapidjson.org][site] · [`doc/sax.md`][sax] · [`doc/dom.md`][dom] · [`doc/internals.md`][internals]        |
| Key authors               | Milo Yip (miloyip) et al.; © 2015 THL A29 Limited, a Tencent company, and Milo Yip                         |
| Category                  | High-performance JSON (C++, partial SIMD)                                                                  |
| Algorithm / grammar class | Recursive-descent DOM builder + SAX event parser; strict RFC 7159 / ECMA-404 JSON (optional relaxed modes) |
| Lexing model              | Scannerless, character-at-a-time recursive descent; SIMD accelerates whitespace-skip and string-scan only  |
| Latest release            | `v1.1.0` (2016-08-25)                                                                                      |

> [!NOTE]
> RapidJSON is a single-grammar parser, like [simdjson][simdjson] — not a generator or combinator toolkit. Its place in this survey is as the **reference point the SIMD generation measured itself against**: simdjson's paper reports parsing "_4x faster than RapidJSON_" and using "_a quarter or fewer instructions than a state-of-the-art reference parser like RapidJSON_" ([simdjson][simdjson]). Reading the two back to back is the sharpest available before/after picture of what whole-input SIMD changed. It shares the fast-JSON category with [`simd-json`][simd-json], [`sonic-rs`][sonic-rs], and [`yyjson`][yyjson].

---

## Overview

### What it solves

RapidJSON is "**a fast JSON parser/generator for C++ with both SAX/DOM style API**" ([`readme.md`][repo]). It set the practical performance bar for C++ JSON in the mid-2010s by pairing a tightly template-specialized recursive-descent parser with aggressive memory discipline. The [`readme.md`][repo] summarizes the four pillars:

> _"RapidJSON is **small** but **complete**. It supports both SAX and DOM style API. … RapidJSON is **fast**. Its performance can be comparable to `strlen()`. It also optionally supports SSE2/SSE4.2 for acceleration. … RapidJSON is **self-contained** and **header-only**. It does not depend on external libraries such as BOOST. It even does not depend on STL. … RapidJSON is **memory-friendly**. Each JSON value occupies exactly 16 bytes for most 32/64-bit machines (excluding text string)."_
> — [`readme.md`][repo]

It targets strict compliance — "**in full compliance with RFC7159/ECMA-404**, with optional support of relaxed syntax" ([`readme.md`][repo]) — with full Unicode: "**Unicode-friendly**. It supports UTF-8, UTF-16, UTF-32 (LE & BE), and their detection, validation and transcoding internally" ([`readme.md`][repo]).

### Design philosophy

Three ideas run through the codebase:

1. **Static binding over virtual dispatch.** The SAX `Reader` and its user `Handler` are bound _at compile time_ through templates, so event calls inline: "_RapidJSON uses templates to statically bind the `Reader` type and the handler type, instead of using classes with virtual functions. This paradigm can improve performance by inlining functions_" ([`doc/sax.md`][sax]). Parse flags are non-type template parameters, so "_C++ compiler can generate code which is optimized for specified combinations, improving speed, and reducing code size_" ([`doc/dom.md`][dom]).

2. **SAX is the substrate; DOM is built on it.** The DOM `Document` is itself a SAX `Handler`: "_The DOM style API (`rapidjson::GenericDocument`) is actually implemented with SAX style API (`rapidjson::GenericReader`). SAX is faster but sometimes DOM is easier_" ([`doc/features.md`][features]).

3. **Never copy what you can point at.** In-situ parsing decodes strings in place, short-string optimization inlines small strings into the `Value`, and the default `MemoryPoolAllocator` bump-allocates and never frees individually. The goal throughout is cache coherence and minimal allocation.

RapidJSON is deliberately lean: it compiles "**Without C++ exception, RTTI**" and includes only `<cstdio>`, `<cstdlib>`, `<cstring>`, `<inttypes.h>`, `<new>`, `<stdint.h>` ([`doc/features.md`][features]).

---

## How it works

### The SAX core — `GenericReader` → `Handler`

`Reader` (a typedef of `GenericReader`) "_parses a JSON from a stream. While it reads characters from the stream, it analyzes the characters according to the syntax of JSON, and publishes events to a handler_" ([`doc/sax.md`][sax]). The handler is a concept — any type exposing the fourteen event methods:

```cpp
concept Handler {
    bool Null();
    bool Bool(bool b);
    bool Int(int i);   bool Uint(unsigned i);
    bool Int64(int64_t i);  bool Uint64(uint64_t i);
    bool Double(double d);
    bool RawNumber(const Ch* str, SizeType length, bool copy);
    bool String(const Ch* str, SizeType length, bool copy);
    bool StartObject();  bool Key(const Ch* str, SizeType length, bool copy);
    bool EndObject(SizeType memberCount);
    bool StartArray();   bool EndArray(SizeType elementCount);
};
```

([`include/rapidjson/reader.h`][reader]) On a number the reader "_chooses a suitable C++ type mapping_" and calls exactly one of `Int`/`Uint`/`Int64`/`Uint64`/`Double` ([`doc/sax.md`][sax]). Every event returns `bool`: "_If the handler encounters an error, it can return `false` to notify the event publisher to stop further processing_" — placing the reader in an error state with code `kParseErrorTermination` ([`doc/sax.md`][sax]). Because `Reader`, `Writer` (the SAX generator), and `Document` all speak the same event vocabulary and none depend on the others, they chain freely: piping a `Reader` straight into a `Writer` removes whitespace (`condense`), into a `PrettyWriter` reformats (`pretty`), and an intermediate filter can transform events on the fly (`capitalize`) ([`doc/sax.md`][sax], [`doc/internals.md`][internals]).

### The DOM layer — `GenericDocument` and `GenericValue`

`Value` (= `GenericValue<UTF8<>>`) and `Document` (= `GenericDocument<UTF8<>>`) are typedefs of templates parameterized on `Encoding` and `Allocator` ([`doc/dom.md`][dom]). `Document` _is_ a `Handler`: "_`Document` is a handler which receives events from a reader to build a DOM during parsing_" ([`doc/sax.md`][sax]). The inverse direction is `Value::Accept(Handler&)`, which "_is responsible for publishing SAX events about the value to the handler_" ([`doc/dom.md`][dom]) — this is why stringifying a DOM is written `d.Accept(writer)`.

`Value` is a **variant packed into 16 bytes**. From [`doc/internals.md`][internals]:

> _"`Value` is a [variant type]. In RapidJSON's context, an instance of `Value` can contain 1 of 6 JSON value types. This is possible by using `union`. Each `Value` contains two members: `union Data data_`and a`unsigned flags*`. The `flags*` indicates the JSON type, and also additional information."\_

The `flags_` word carries both a sequential type tag and redundant capability bits (`kIntFlag`, `kUintFlag`, `kInt64Flag`, `kDoubleFlag`, …) so that `IsNumber()` is a single bit-test and integers auto-widen: "_An `Int` is always an `Int64`, but the converse is not always true_" ([`doc/internals.md`][internals]).

### Short-string optimization

Small strings live _inside_ the 16-byte `Value`, avoiding a heap allocation and a pointer chase ([`doc/internals.md`][internals]):

> _"Excluding the `flags_`, a `Value`has 12 or 16 bytes (32-bit or 64-bit) for storing actual data. Instead of storing a pointer to a string, it is possible to store short strings in these space internally. For encoding with 1-byte character type (e.g.`char`), it can store maximum 11 or 15 characters string inside the `Value` type."\_

A neat trick stores `MaxChars - length` as the in-band length byte "_to store 11 characters with trailing `\0`_" and improves cache coherence ([`doc/internals.md`][internals]).

### In-situ parsing — destructive zero-copy

The signature RapidJSON idea. `ParseInsitu(Ch* str)` "_decodes those JSON string at the place where it is stored. It is possible in JSON because the length of decoded string is always shorter than or equal to the one in JSON_" ([`doc/dom.md`][dom]). Decoding an escape (`\n`, `s`) only ever _shrinks_ the text, so the result fits over the original bytes; an escape-free string like `"msg"` is handled by simply overwriting its closing quote with `'\0'` ([`doc/dom.md`][dom]). The DOM's string `Value`s then point directly into the caller's mutated buffer — the `String()` event fires with `copy = false` ([`doc/sax.md`][sax]). Formally it is an **O(1) auxiliary space** algorithm ([`doc/dom.md`][dom]):

> _"In situ parsing minimizes allocation overheads and memory copying. Generally this improves cache coherence, which is an important factor of performance in modern computer."_

The cost is a sharp usage contract: the API takes `char*` not `const char*`, the whole JSON must be in memory, source and target encodings must match, and "_The buffer need to be retained until the document is no longer used_" ([`doc/dom.md`][dom]) — dangling pointers otherwise. It suits "_short-term JSON that only need to be processed once, and then be released_" — deserializing to C++ objects, handling web requests ([`doc/dom.md`][dom]).

### MemoryPoolAllocator — bump-allocate, never free

The default DOM allocator "_allocate but do not free memory. This is suitable for building a DOM tree_" ([`doc/internals.md`][internals]). Internally it "_allocates chunks of memory from the base allocator (by default `CrtAllocator`) and stores the chunks as a singly linked list_," serving requests from (1) an optional user-supplied buffer, then (2) the current chunk, then (3) a freshly allocated chunk ([`doc/internals.md`][internals]). A user buffer — stack array or static scratch — can make a parse allocation-free entirely: "_If the total size of allocation is less than 4096+1024 bytes during parsing, this code does not invoke any heap allocation … at all_" ([`doc/dom.md`][dom]). The alternative `CrtAllocator` wraps `malloc`/`realloc`/`free` and is "_far less efficient_" but supports piecemeal deallocation ([`doc/dom.md`][dom]).

### The one place SIMD lives — `SkipWhitespace_SIMD`

This is the crux of RapidJSON's contrast with [simdjson][simdjson]: **SIMD is a peephole optimization, not the parser.** It accelerates whitespace skipping (and, similarly, string-content scanning), while the parse itself stays scalar and character-at-a-time. From [`doc/internals.md`][internals]:

> _"To accelerate this process, SIMD was applied to compare 16 characters with 4 white spaces for each iteration. Currently RapidJSON supports SSE2, SSE4.2 and ARM Neon instructions for this. And it is only activated for UTF-8 memory streams, including string stream or *in situ* parsing."_

The SSE4.2 path uses one `_mm_cmpistri` (`pcmpistrm`) per 16 bytes against the 4-char whitespace set, returning the index of the first non-whitespace ([`include/rapidjson/reader.h`][reader]):

```cpp
static const char whitespace[16] = " \n\r\t";
const __m128i w = _mm_loadu_si128(reinterpret_cast<const __m128i *>(&whitespace[0]));
for (;; p += 16) {
    const __m128i s = _mm_load_si128(reinterpret_cast<const __m128i *>(p));
    const int r = _mm_cmpistri(w, s, _SIDD_UBYTE_OPS | _SIDD_CMP_EQUAL_ANY | _SIDD_LEAST_SIGNIFICANT | _SIDD_NEGATIVE_POLARITY);
    if (r != 16)    // some of characters is non-whitespace
        return p + r;
}
```

The SSE2 fallback does four `_mm_cmpeq_epi8` compares OR'd together, then `_mm_movemask_epi8` + a bit-scan for the first mismatch; a NEON variant mirrors it ([`include/rapidjson/reader.h`][reader]). The same `_mm_cmpeq_epi8`/`_mm_max_epu8` pattern scans string bodies for `"`, `\`, and control bytes (`< 0x20`) during `ParseStringToStream` ([`include/rapidjson/reader.h`][reader]). All of this is **compile-time gated** by `RAPIDJSON_SSE2` / `RAPIDJSON_SSE42` / `RAPIDJSON_NEON`: "_these are compile-time settings. Running the executable on a machine without such instruction set support will make it crash_" ([`doc/internals.md`][internals]) — there is no runtime CPU dispatch, unlike simdjson. A historical **page-boundary bug** (a `_mm_loadu_si128` reading past `'\0'` across a protected page, crashing ~1 in 500,000) was fixed by first advancing to the next aligned address, then using aligned reads ([`doc/internals.md`][internals]).

### Number parsing

By default numbers use `internal::StrtodNormalPrecision()`, which "_has maximum 3 ULP error_" and is fast ([`doc/internals.md`][internals]). `kParseFullPrecisionFlag` switches to `internal::StrtodFullPrecision()`, which tries three methods in order — a decimal fast-path, a DIY-FP implementation (as in Google's `double-conversion`), and Clinger's Big-Integer method — falling through on failure ([`doc/internals.md`][internals]). Generation is symmetric: a header-only **Grisu2** for double-to-string ("_always accurate … in most of cases it produces the shortest (optimal) string representation_") and `branchlut` for integer-to-string ([`doc/internals.md`][internals]).

### Encodings & transcoding

`GenericReader<SourceEncoding, TargetEncoding, Allocator>` decouples the stream encoding from the emitted-string encoding, so a UTF-8 stream can produce UTF-16 `String()` events ([`doc/sax.md`][sax]). During transcoding "_the source string is decoded into Unicode code points, and then the code points are encoded in the target format_," validating the byte sequence and failing with `kParseErrorStringInvalidEncoding` on a bad sequence ([`doc/dom.md`][dom]). When source and target encodings match, validation is skipped unless `kParseValidateEncodingFlag` is set ([`doc/dom.md`][dom]).

---

## Algorithm & grammar class

RapidJSON parses **exactly one grammar — strict JSON** (RFC 7159 / ECMA-404), with optional relaxed extensions (comments, trailing commas, `NaN`/`Inf`), and offers two engines for it:

- **Recursive-descent (default).** `Parse` dispatches through `ParseValue` → `ParseObject` / `ParseArray` / `ParseString` / `ParseNumber`, recursing on the C++ call stack. "_Recursive parser is faster but prone to stack overflow in extreme cases_" ([`doc/features.md`][features]).
- **Iterative (`kParseIterativeFlag`).** "_The iterative parser is a recursive descent LL(1) parser implemented in a non-recursive manner_" ([`doc/internals.md`][internals]). Left-factoring the `values`/`members` productions makes the grammar `LL(1)`; the [FIRST/FOLLOW parsing table][internals] is then "_encoded in a state machine_" with extra states for array/object element counting, giving "_constant complexity in terms of function call stack size_" ([`include/rapidjson/reader.h`][reader], [`doc/internals.md`][internals]).

**Ambiguity does not arise** — JSON is `LL(1)` with single-token lookahead, exactly the property the iterative parser's table exploits (see [top-down / recursive descent][top-down] and [formal languages][formal]). This is the _character-at-a-time recursive-descent_ end of the design space — the antithesis of simdjson's [whole-input SIMD structural indexing][simdjson].

## Interface & composition model

There is **no grammar DSL or combinator** — the surface is JSON-in, events-or-tree-out — but two composition axes stand out:

| API     | Shape                                                                             | When                                                       |
| ------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| **SAX** | `GenericReader` → user `Handler`; `Writer`/`PrettyWriter` consume the same events | Streaming, filtering, custom in-memory structures, min RAM |
| **DOM** | `GenericDocument` builds a `GenericValue` tree; `Value::Accept` re-emits events   | Random access, mutation, re-serialization                  |

The `Handler` concept is the composition primitive: because `Reader`, `Writer`, `Document`, and any user filter all implement it, they form pipelines (`Reader → Filter → Writer`) with no shared base class ([`doc/internals.md`][internals]). The DOM tree is built **fully** (unlike simdjson's lazy On Demand), but a SAX handler can build a custom, smaller structure — the `messagereader` example populates a `std::map` directly, "_eliminat[ing] building of DOM, thus reducing memory and improving performance_" ([`doc/sax.md`][sax]).

## Performance

Performance is the reason RapidJSON existed; the concrete posture:

- **Throughput.** README claims performance "_comparable to `strlen()`_" ([`readme.md`][repo]); it long topped the [nativejson-benchmark][nativejson] collection. Relative to the SIMD generation it is now the _baseline_: simdjson reports ~4× higher throughput and, per its paper, RapidJSON at **18.7 instructions/byte** vs simdjson's 8.3 ([simdjson][simdjson]).
- **In-situ zero-copy.** No string allocation and no copy for escape-free strings; O(1) auxiliary memory ([`doc/dom.md`][dom]).
- **Allocation.** Bump-pointer `MemoryPoolAllocator` with optional user buffer → parses with zero heap allocation when the buffer suffices ([`doc/dom.md`][dom]).
- **SIMD.** Narrow — whitespace skip and string-body scan only, 16 bytes/iteration, compile-time-gated, no runtime dispatch ([`doc/internals.md`][internals]). The parse loop itself is scalar.
- **Value footprint.** Exactly 16 bytes per `Value` on most machines; short strings inlined ([`readme.md`][repo], [`doc/internals.md`][internals]).
- **Backtracking / memoization.** None — `LL(1)` recursive descent with single-token lookahead, one forward pass.

## Error handling & recovery

RapidJSON is a **strict, fail-fast validator** — no recovery, no resynchronization. On the first violation it stops and records a `ParseErrorCode` plus a character offset: the DOM has `HasParseError()`, `GetParseError()`, and `GetErrorOffset()`, and "_When there is an error, the original DOM is *unchanged*_" ([`doc/dom.md`][dom]). The error enum is granular — `kParseErrorObjectMissColon`, `kParseErrorStringUnicodeSurrogateInvalid`, `kParseErrorNumberTooBig`, `kParseErrorTermination`, and a dozen more ([`doc/dom.md`][dom]) — and `rapidjson/error/en.h` maps codes to English messages, with localization left to the user. The offset is a raw character count: "_Currently RapidJSON does not keep track of line number_" ([`doc/dom.md`][dom]). A handler returning `false` aborts the parse with `kParseErrorTermination`, which is how streaming validators reject early ([`doc/sax.md`][sax]). There is **no incremental reparse and no IDE-grade diagnostics** — for that tolerant, error-recovering end of the space, see [`tree-sitter`][comparison] via the [comparison][comparison]. Multiple concatenated JSON documents in one stream are supported via `kParseStopWhenDoneFlag` ([`doc/dom.md`][dom]).

## Ecosystem & maturity

RapidJSON is a mature, widely-vendored Tencent open-source project (© 2015 THL A29 Limited, a Tencent company, and Milo Yip). Distribution is frictionless — header-only, "_Just copy the `include/rapidjson` folder_" ([`readme.md`][repo]) — with vcpkg and CMake `find_package(RapidJSON)` integration. It ships a broad example set (DOM tutorial; SAX `simplereader`, `condense`, `pretty`, `capitalize`, `messagereader`, `serialize`, `jsonx`; `schemavalidator`; and advanced `prettyauto`, `parsebyparts`, `filterkey`) and a googletest-based unit + performance test suite ([`readme.md`][repo]). Standards coverage beyond core JSON includes JSON Pointer (RFC 6901), JSON Schema Draft v4, Swagger v2 / OpenAPI v3.0 schema, and NPM compliance ([`doc/features.md`][features]). The **v1.1.0** release (2016-08-25) added JSON Pointer, JSON Schema, relaxed syntax, C++11 range-based iteration, and shrank `Value` from 24 to 16 bytes on x86-64 ([`readme.md`][repo]).

> [!NOTE]
> The pinned tree carries a version discrepancy worth flagging: the [`readme.md`][repo] claims "_full compliance with RFC7159/ECMA-404_," while [`doc/features.md`][features] says "_fully RFC4627/ECMA-404 compliance_." RFC 7159 obsoletes RFC 4627; the README is the newer, authoritative statement.

---

## Strengths

- **Battle-tested, header-only, dependency-free** — no STL/BOOST, no exceptions/RTTI, trivial to vendor.
- **Dual SAX + DOM on one event vocabulary** — stream, filter, or build a tree; pipelines compose without a shared base class.
- **In-situ destructive parsing** — O(1) auxiliary memory, no string copies, cache-friendly for parse-once workloads.
- **Aggressive memory discipline** — 16-byte `Value`, short-string inlining, bump-pointer pool allocator, optional zero-heap parsing via a user buffer.
- **Full Unicode** — UTF-8/16/32 (LE & BE), detection, validation, and transcoding between stream and DOM encodings.
- **Compile-time specialization** — template-bound handler + non-type parse-flag template parameters inline the hot path.
- **Accurate numbers on demand** — Grisu2 output, optional full-precision (correctly-rounded) input parsing.

## Weaknesses

- **One grammar only** — not a parsing toolkit; you cannot express another language. (By design.)
- **SIMD is narrow and static** — only whitespace/string scanning is vectorized, and the ISA is chosen at _compile time_ with **no runtime dispatch**; a binary built for SSE4.2 crashes on a CPU without it. This is precisely the ceiling [simdjson][simdjson] broke by making SIMD the whole parse.
- **No error recovery, no incremental reparse** — first-error-and-stop; offsets are character counts with **no line numbers**; wrong tool for an editor or LSP.
- **In-situ's contract is sharp** — mutates the caller's buffer, needs `char*`, source/target encodings must match, and the buffer must outlive the DOM.
- **Recursive parser can stack-overflow** on deeply nested input unless you opt into the iterative `LL(1)` engine.
- **`MemoryPoolAllocator` never frees individually** — great for parse-then-discard, wasteful for long-lived, heavily-mutated DOMs (use `CrtAllocator` there).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                         | Trade-off                                                                                    |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **SAX as substrate, DOM as a `Handler` on top**                  | One event model powers streaming, filtering, tree-building, and re-serialization  | DOM users pay for a generic event interface; SAX is faster but forces manual state-keeping   |
| **Template/static binding of reader + handler**                  | Events inline; parse flags as template params specialize the hot path             | Flags must be compile-time constants; more instantiations / code bloat                       |
| **In-situ destructive parsing** (`ParseInsitu`)                  | O(1) extra memory, no string copies, cache-friendly                               | Mutates and pins the input buffer; `char*` API; encodings must match                         |
| **16-byte `Value` variant + short-string inlining**              | Small footprint, fewer allocations and pointer chases, better cache behavior      | 11/15-char inline cap; bit-packed `flags_` is intricate                                      |
| **`MemoryPoolAllocator` (bump, no per-object free)**             | Fastest possible allocation for build-once DOMs; optional user buffer → zero heap | Cannot reclaim individual nodes; unsuited to churn-heavy DOMs                                |
| **SIMD only for whitespace/string scan, compile-time ISA**       | Cheap, targeted win on a measured hot spot without rewriting the parser           | No runtime dispatch (mis-targeted binary crashes); leaves the scalar parse as the bottleneck |
| **Recursive descent by default, iterative `LL(1)` opt-in**       | Recursion is fastest; iterative bounds stack for adversarial nesting              | Default risks stack overflow; iterative table/state-machine is more complex                  |
| **Strict validation, first-error-stop, char-offset diagnostics** | Keeps the hot path simple and fast; rejects malformed input outright              | No recovery, no line numbers, no incremental reparse — useless for editors/LSPs              |
| **Normal-precision floats by default, full-precision opt-in**    | Fast common path (≤ 3 ULP); correctness on demand                                 | Default is not correctly-rounded; full precision is slower                                   |

---

## Sources

- [`Tencent/rapidjson` — GitHub repository][repo] · [rapidjson.org][site]
- [`readme.md` — positioning, four pillars, v1.1.0 highlights, examples][repo]
- [`doc/sax.md` — `Reader`/`Handler`/`Writer`, static binding, event pipeline][sax]
- [`doc/dom.md` — `GenericValue`/`GenericDocument`, in-situ parsing, allocators, parse errors, transcoding][dom]
- [`doc/internals.md` — `Value` layout, short-string opt, `MemoryPoolAllocator`, `SkipWhitespace_SIMD`, iterative `LL(1)` parser, float parsing][internals]
- [`doc/features.md` — feature matrix, standards compliance, recursive vs iterative][features]
- [`include/rapidjson/reader.h` — `ParseFlag`, `Handler` concept, `SkipWhitespace_SIMD` (SSE2/SSE4.2/NEON), `ParseStringToStream`][reader]
- `license.txt` — MIT license (source); JSON license confined to `bin/jsonchecker/`
- Related: [umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison] · [simdjson][simdjson] · [`simd-json`][simd-json] · [`sonic-rs`][sonic-rs] · [`yyjson`][yyjson] · [Hyperscan][hyperscan] · [top-down / recursive descent][top-down] · [formal languages][formal]

<!-- References -->

[repo]: https://github.com/Tencent/rapidjson
[site]: https://rapidjson.org/
[sax]: https://github.com/Tencent/rapidjson/blob/24b5e7a8b27f42fa16b96fc70aade9106cf7102f/doc/sax.md
[dom]: https://github.com/Tencent/rapidjson/blob/24b5e7a8b27f42fa16b96fc70aade9106cf7102f/doc/dom.md
[internals]: https://github.com/Tencent/rapidjson/blob/24b5e7a8b27f42fa16b96fc70aade9106cf7102f/doc/internals.md
[features]: https://github.com/Tencent/rapidjson/blob/24b5e7a8b27f42fa16b96fc70aade9106cf7102f/doc/features.md
[reader]: https://github.com/Tencent/rapidjson/blob/24b5e7a8b27f42fa16b96fc70aade9106cf7102f/include/rapidjson/reader.h
[nativejson]: https://github.com/miloyip/nativejson-benchmark
[simdjson]: ./simdjson.md
[simd-json]: ./simd-json.md
[sonic-rs]: ./sonic-rs.md
[yyjson]: ./yyjson.md
[hyperscan]: ./hyperscan.md
[formal]: ./theory/formal-languages.md
[top-down]: ./theory/top-down.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
