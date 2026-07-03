# yyjson (ANSI C)

A high-performance JSON reader/writer written in portable **ANSI C (C89) with _no explicit SIMD_** — the deliberate scalar counterpoint to [simdjson][simdjson]: it reaches gigabytes-per-second throughput through careful branch layout, a hand-tuned number reader/writer, and a single-allocation contiguous-array document, shipped as "just one `.h` and one `.c` file."

| Field                  | Value                                                                                                     |
| ---------------------- | --------------------------------------------------------------------------------------------------------- |
| Language               | ANSI C (C89)                                                                                              |
| License                | MIT (`Copyright (c) 2020 YaoYuan`)                                                                        |
| Repository             | [`ibireme/yyjson`][repo]                                                                                  |
| Documentation          | [`doc/API.md`][api] · [`doc/DataStructure.md`][ds] · [Doxygen][doxy]                                      |
| Author                 | YaoYuan (`ibireme`) and contributors                                                                      |
| Category               | High-performance JSON — **scalar, no SIMD**                                                               |
| Algorithm class        | Hand-tuned scalar recursive-goto DOM parser over a single-allocation value arena                          |
| Performance posture    | GB/s throughput **without SIMD** (scalar C, branch-layout-tuned)                                          |
| Zero-copy / allocation | Single-`malloc` contiguous `yyjson_val` arena + one contiguous string pool; optional in-situ string reuse |
| Notes                  | One `.h` + one `.c`; RFC 8259 strict; JSON5 & JSON Pointer/Patch/Merge-Patch; incremental reader          |

> [!NOTE]
> yyjson is not a parser _generator_ or a combinator library — like [simdjson][simdjson] it parses exactly one grammar (JSON, plus opt-in JSON5 extensions). Its interest to this survey is entirely in **how** it reaches SIMD-class speed _without_ SIMD: it is the catalog's evidence that the high-performance-JSON result is not exclusively a data-parallel one. It belongs in the "high-performance / data-parallel" cluster with a **no-SIMD asterisk**, and reads best against the vectorized [simdjson][simdjson], [`simd-json`][simd-json], and [`sonic-rs`][sonic-rs], and against the older scalar DOM parser [`rapidjson`][rapidjson] it benchmarks past.

---

## Overview

### What it solves

Ingesting and emitting JSON at the speed of the underlying storage/network is a recurring systems bottleneck, and the field's headline answer — [simdjson][simdjson] — leans on wide SIMD registers, runtime CPU dispatch, and a padding contract on the input buffer. yyjson stakes out the opposite position: that a **single, dependency-free, strictly-portable C file** can rival those numbers on real documents while running on any C89 compiler and any 64-bit (or even freestanding/embedded) target. The [`README`][repo] states the five design pillars verbatim:

> - **Fast**: can read or write gigabytes of JSON data per second on modern CPUs.
> - **Portable**: complies with ANSI C (C89), no explicit SIMD.
> - **Strict**: complies with [RFC 8259](https://datatracker.ietf.org/doc/html/rfc8259) JSON standard, ensuring strict number formats and UTF-8 validation.
> - **Accuracy**: can accurately read and write `int64`, `uint64`, and `double` numbers.
> - **Developer-Friendly**: easy integration with just one `.h` and one `.c` file.
>   — [`README.md`][repo], "Features"

The "no explicit SIMD" claim is verifiable in the tree: `src/yyjson.c` contains **zero** `_mm_*` / `__m128` / `immintrin.h` / NEON intrinsics — the entire reader and writer are scalar C. The performance therefore comes from _algorithmic and microarchitectural_ care rather than vector width, which is the whole point of including it here.

### Design philosophy

Three ideas recur throughout the source:

1. **Scalar, but microarchitecture-aware.** The [`README`][repo] is explicit that the speed is a property of _how the CPU runs ordinary code_, not of vector units. "For better performance, yyjson prefers" a processor with "high instruction level parallelism," an "excellent branch predictor," and "low penalty for misaligned memory access," plus "a modern compiler with good optimizer (e.g. clang)" ([`README.md`][repo]). The hot loops are written to feed exactly those features (see [How it works](#how-it-works)).

2. **One document, few allocations.** A parsed document is not a tree of individually-allocated nodes but a **contiguous array** of fixed-size `yyjson_val` cells plus one contiguous string pool — sized up-front from a byte-per-value estimate and grown by geometric `realloc` only if the estimate is exceeded. "A JSON document stores all values in … a **contiguous** memory area" and "stores all strings in a **contiguous** memory area … unescaped in-place and ended with a null-terminator" ([`doc/DataStructure.md`][ds]).

3. **Immutable read, mutable build — separated on purpose.** Reading yields an immutable document optimized for compact storage and traversal; modification uses a separate mutable representation. "JSON parsing results are immutable, requiring a mutable copy for modification" ([`README.md`][repo], "Limitations"). This is a deliberate trade the [Key design decisions](#key-design-decisions-and-trade-offs) table revisits.

---

## How it works

### The immutable document — a DOM/tape hybrid

The read path produces a `yyjson_doc` that owns two contiguous blocks. Each value is a 16-byte cell ([`doc/DataStructure.md`][ds]):

```c
struct yyjson_val {
    uint64_t tag;
    union {
        uint64_t    u64;
        int64_t     i64;
        double      f64;
        const char *str;
        void       *ptr;
        size_t      ofs;
    } uni;
}
```

The `tag` packs both type and size into one word: "The type of the value is stored in the lower 8 bits of the `tag`. The size of the value, such as string length, object size, or array size, is stored in the higher 56 bits" ([`doc/DataStructure.md`][ds]). Storing the size inline is safe because "modern 64-bit processors are typically limited to supporting fewer than 64 bits for RAM addresses … a 52-bit (4PB) physical address limit" ([`doc/DataStructure.md`][ds]).

Containers do not store child pointers. An `object`/`array` cell "store[s] their own memory usage, allowing easy traversal of the child values" — its children are the cells laid out immediately after it in the array, and it records the `ofs` to the next sibling. This is the **tape idea** (as in [simdjson][simdjson]'s DOM tape) fused with a navigable DOM: contiguous, cache-friendly, pointer-free, and traversed by walking offsets. The trade appears in the [`README`][repo] "Limitations": "an array or object is stored as a [data structure] such as linked list, which makes accessing elements by index or key slower than using an iterator" — so idiomatic access uses `yyjson_arr_foreach` / `yyjson_obj_iter` rather than random indexing.

### Single-allocation arena, sized by estimate

The reader allocates the whole value array in **one `malloc`** before parsing, sizing it from the input length divided by a per-shape byte-per-value estimate ([`src/yyjson.c`][src]):

```c
#define YYJSON_READER_ESTIMATED_PRETTY_RATIO 16
#define YYJSON_READER_ESTIMATED_MINIFY_RATIO 6
...
alc_len = hdr_len + (dat_len / YYJSON_READER_ESTIMATED_MINIFY_RATIO) + 4;
val_hdr = (yyjson_val *)alc.malloc(alc.ctx, alc_len * sizeof(yyjson_val));
```

`yyjson_read_opts` sniffs the first bytes and dispatches to one of three specialized root readers — `read_root_single` (a lone scalar/one value), `read_root_minify` (compact JSON, ~6 bytes/value), or `read_root_pretty` (whitespace-formatted, ~16 bytes/value) — so each hot loop is specialized to its whitespace regime ([`src/yyjson.c`][src]). If the estimate is too small the array is grown geometrically (`alc_len += alc_len / 2`, then `realloc`) — a rare path for well-formed input. The document header itself lives at the front of the same allocation (`hdr_len = sizeof(yyjson_doc) / sizeof(yyjson_val)`), so a small document is genuinely one allocation for structure plus at most one for the string pool.

### Padding handled internally (unlike simdjson)

yyjson's SIMD-free loops still read a few bytes past logical end, so it needs `YYJSON_PADDING_SIZE` trailing zero bytes — but by default it **supplies that padding itself** by copying the caller's input into an owned buffer, so the public contract needs no special buffer ([`src/yyjson.c`][src]):

```c
} else { /* not INSITU */
    hdr = (u8 *)alc.malloc(alc.ctx, len + YYJSON_PADDING_SIZE);
    ...
    memcpy(hdr, dat, len);
}
memset(eof, 0, YYJSON_PADDING_SIZE);
```

The header documents that `dat` needs no null-terminator and "will not be modified without the flag `YYJSON_READ_INSITU`" ([`src/yyjson.h`][hdr]). This is a real ergonomic contrast with [simdjson][simdjson], whose On-Demand API pushes the `SIMDJSON_PADDING` / `padded_string` requirement onto the caller. yyjson's cost is a copy; its **`YYJSON_READ_INSITU`** flag opts back into simdjson-style zero-copy — the reader then "modif[ies] and use[s] input data to store string values," the caller keeps the buffer alive and pre-pads it, "which can increase reading speed slightly" ([`src/yyjson.h`][hdr]). The benchmark tables show `insitu` is the fastest configuration.

### The number reader — a hand-written correctly-rounded parser

yyjson's own float/int reader is where much of the scalar speed and the "Accuracy" claim live; it is a tiered algorithm ([`src/yyjson.c`][src]).

- **Integers** are read by a manually **unrolled 1..18-digit loop** (`repeat_in_1_18(expr_intg)`), accumulating `sig = num + sig * 10` with a `likely` branch per digit and a jump table of `digi_sepr_##i` labels for the terminating character — a branch-layout-tuned scalar equivalent of simdjson's `parse_eight_digits_unrolled`. 19- and 20-digit integers get overflow-checked slow tails; overflow falls back to `double` (or raw with `YYJSON_READ_BIGNUM_AS_RAW`).

- **Doubles, fast path 1:** when the significand fits in 53 bits and the exponent is small, the value is computed by a single scalar FP multiply/divide against a `f64_pow10_table`, guarded by `YYJSON_DOUBLE_MATH_CORRECT` and round-to-nearest ([`src/yyjson.c`][src], "Fast path 1").

- **Doubles, fast path 2:** otherwise it converts `10^exp` to `sig2 * 2^exp2` from a cached 128-bit power-of-ten significand table and does a 128-bit `u128_mul`, checking whether the top 53 bits plus a rounding bit are exactly determined — an **Eisel-Lemire-style** correctly-rounded multiply, all in scalar `u64` arithmetic ([`src/yyjson.c`][src], "Fast path 2").

- **Doubles, slow path:** for the rare undecidable case it falls to a `diy_fp` approximation plus a `bigint` (`u64 bits[64]`) exact comparison — "This algorithm refers to google's double-conversion project" ([`src/yyjson.c`][src]). A `strtod()`-based path also exists behind compile options, with careful locale handling ([`src/yyjson.c`][src]).

Writing numbers is the mirror image: `f64_bin_to_dec` implements the **Schubfach** shortest-round-trip algorithm — "Raffaello Giulietti, The Schubfach way to render doubles, 2022" ([`src/yyjson.c`][src]) — with its own fast path. Together these give the "can accurately read and write `int64`, `uint64`, and `double`" guarantee without calling into libc on the hot path.

### Read/write flags — one grammar, many opt-in dialects

Behaviour is controlled by a bitset of flags rather than a grammar. The default (`YYJSON_READ_NOFLAG`) is strict RFC 8259: it will "report error on trailing commas, comments, inf and nan literals," "report error if string contains invalid UTF-8 character or BOM," and "report error if double number is infinity" ([`src/yyjson.h`][hdr]). Notable read flags ([`src/yyjson.h`][hdr]):

| Flag                                                       | Effect                                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `YYJSON_READ_INSITU`                                       | Parse in place, storing unescaped strings in the caller's padded buffer        |
| `YYJSON_READ_STOP_WHEN_DONE`                               | Stop after one document instead of erroring on trailing content (for `NDJSON`) |
| `YYJSON_READ_NUMBER_AS_RAW`                                | Keep every number as its verbatim source text (`YYJSON_TYPE_RAW`)              |
| `YYJSON_READ_BIGNUM_AS_RAW`                                | Keep only out-of-range int/float as raw text                                   |
| `YYJSON_READ_ALLOW_INF_AND_NAN`                            | Accept `inf`/`nan` literals and `1e999`                                        |
| `YYJSON_READ_ALLOW_INVALID_UNICODE`                        | Permit invalid encoding in string values (with a security `@warning`)          |
| `YYJSON_READ_ALLOW_TRAILING_COMMAS` / `_COMMENTS` / `_BOM` | Individual non-standard relaxations                                            |
| `YYJSON_READ_JSON5`                                        | Composite flag enabling the full [JSON5][json5] feature set                    |

Write flags (`YYJSON_WRITE_PRETTY`, `YYJSON_WRITE_ESCAPE_UNICODE`, `YYJSON_WRITE_ESCAPE_SLASHES`, `YYJSON_WRITE_ALLOW_INF_AND_NAN`, `YYJSON_WRITE_INF_AND_NAN_AS_NULL`, `YYJSON_WRITE_PRETTY_TWO_SPACES`, `YYJSON_WRITE_NEWLINE_AT_END`, `YYJSON_WRITE_LOWERCASE_HEX`, …) mirror this on the output side ([`src/yyjson.h`][hdr]).

### Mutable documents, incremental reads, and pointers

- **Mutable model.** Building/editing uses `yyjson_mut_doc` / `yyjson_mut_val`, where each value adds a `next` field and container children form a **circular linked list whose parent holds the tail**, so `append`, `prepend`, and `remove_first` are O(1) ([`doc/DataStructure.md`][ds]). Convert with `yyjson_doc_mut_copy` (immutable → mutable) and back. This is why editing is a separate representation, not an in-place mutation of the tape.

- **Incremental reader.** `yyjson_incr_new` / `yyjson_incr_read` / `yyjson_incr_free` parse a large document in bounded chunks; a short read returns `YYJSON_READ_ERROR_MORE` and "parsing state is preserved" ([`src/yyjson.h`][hdr]). It "only supports standard JSON" ([`src/yyjson.h`][hdr]) — no JSON5 in incremental mode.

- **Query & patch.** yyjson implements [JSON Pointer (RFC 6901)][rfc6901], [JSON Patch (RFC 6902)][rfc6902], and [JSON Merge Patch (RFC 7386)][rfc7386] (`yyjson_ptr_get*`, `yyjson_patch`, `yyjson_merge_patch`) — the manipulation layer promised in the [`README`][repo] "Manipulation" pillar.

---

## Algorithm & grammar class

yyjson parses **exactly one grammar — RFC 8259 JSON** (with opt-in [JSON5][json5] and other relaxations behind flags). There is no grammar input; the "class" question is about the algorithm.

- **The reader is a hand-written recursive-goto pushdown parser.** JSON nesting is context-free (bracket/brace matching needs a stack), so like [simdjson][simdjson]'s stage 2 it is a pushdown automaton — but yyjson has **no separate structural-indexing stage**: it is a _single scalar pass_ using labelled `goto` state transitions (`obj_key_begin`, `arr_val_begin`, `digi_*`, …) and container-depth tracking, emitting `yyjson_val` cells directly into the arena as it goes. There is no bitset, no SIMD block classification, no two-stage split — the finite-state string/number/whitespace recognition that simdjson vectorizes is here just tightly-written branch code.

- **Ambiguity does not arise** — JSON is unambiguous and `LL(1)`-style; every value's type is fixed by its first byte, which the dispatch on `char_is_ctn` / `char_is_digit` exploits directly.

- **Strict and validating by default.** It rejects malformed numbers (`123.e12`, `000`), invalid UTF-8, unclosed containers, and bad literals, distinguished by fine-grained error codes (`YYJSON_READ_ERROR_INVALID_NUMBER`, `_INVALID_STRING`, `_LITERAL`, `_UNEXPECTED_END`, …) ([`src/yyjson.h`][hdr]). Integers are exact across the full signed-and-unsigned 64-bit range; out-of-range magnitudes degrade to `double` or raw text.

## Interface & composition model

There is **no grammar DSL, no combinator, no generator** — the interface is JSON-in, values-out, via a large C API surface. The document model is the tape/DOM arena above; access is through typed getters (`yyjson_get_str`, `yyjson_get_int`, …), iterators (`yyjson_arr_foreach`, `yyjson_obj_iter`), and the pointer/patch layer. Composition is with the host program, not with other parsers: immutable values borrow into the document's own string pool (or, under `YYJSON_READ_INSITU`, into the caller's buffer), so reads are effectively zero-copy for strings that need no unescaping. Building is the separate mutable API. Unlike [simdjson][simdjson]'s lazy On-Demand iterator, yyjson always **materializes the full document** on read — its speed comes from making that materialization cheap, not from skipping it. (simdjson's own [`README`][repo]-quoted note in yyjson's benchmark section concedes On-Demand "is faster if most JSON fields are known at compile-time.")

## Performance

Performance is the reason yyjson exists, and its central claim — GB/s _without_ SIMD — is what earns it a place beside the vector parsers.

- **Throughput.** The [`README`][repo] benchmark tables (dataset `twitter.json`, project [`yyjson_benchmark`][bench]) report, on AWS EC2 (AMD EPYC 7R32, gcc 9.3): `yyjson(insitu)` **1.80 GB/s** parse and `yyjson` 1.72 GB/s, versus `simdjson` 1.52, `rapidjson(insitu)` 0.77, `cjson` 0.32; on Apple A14 (clang 12): `yyjson(insitu)` **3.51 GB/s** vs `simdjson` 2.19. Stringify shows a larger margin (1.51 vs simdjson 0.61 on EC2).
- **Caveats stated in-repo.** The [`README`][repo] is candid that "the simdjson's new `On Demand` API is faster if most JSON fields are known at compile-time," that "this benchmark project only checks the DOM API," and that the interactive reports were "last updated 2020-12-12." Treat the numbers as directional, DOM-to-DOM, and dated.
- **Complexity.** O(n) time, essentially one forward pass; O(n) space for the value arena plus the string pool. No backtracking, no memoization, no re-scanning — the structural opposite of [PEG/packrat][peg]. The up-front single allocation (sized by the 6-/16-byte estimate) is the dominant memory event; geometric `realloc` only on estimate miss.
- **What makes the scalar code fast.** Container cells store their own extent for pointer-free traversal; the number reader avoids libc on the hot path; the parse loops are specialized per whitespace regime and lean on the branch predictor and ILP the [`README`][repo] calls out. The `insitu` flag removes the input copy and reuses the buffer for unescaped strings.

> [!WARNING]
> The bundled [`doc/Performance.md`][perf] is a stub — its entire contents are the literal text `TODO`. The throughput figures above come from the [`README`][repo] tables and the external [`yyjson_benchmark`][bench] project, which this survey did **not** run locally; they are reproduced as reported, not independently verified.

## Error handling & recovery

yyjson is a **fail-fast strict validator, not a recovering parser** — the same posture as [simdjson][simdjson], and a finding rather than a gap. Every read fills a `yyjson_read_err` with a code, a constant message, and a **byte position** ([`src/yyjson.h`][hdr]):

```c
typedef struct yyjson_read_err {
    yyjson_read_code code; /* see yyjson_read_code */
    const char *msg;       /* constant, no need to free */
    size_t pos;            /* error byte position in input */
} yyjson_read_err;
```

The [`README`][repo] file example prints `read error (%u): %s at position: %ld`. There is **no error recovery, no partial tree, no resynchronization** — a malformed document returns `NULL` at the first error. The error codes are fine-grained (`UNEXPECTED_END` for `[123`, `UNEXPECTED_CHARACTER` for `[abc]`, `JSON_STRUCTURE` for `[1,]`, `INVALID_NUMBER`, `INVALID_STRING`, `LITERAL`, `DEPTH`, plus the incremental `MORE`). This makes it excellent for batch ingestion and validation but the wrong tool for an editor/LSP — for the tolerant, incrementally-reparsing end of the design space see [`tree-sitter`][tree-sitter]; the contrast is as sharp as it is for simdjson.

## Ecosystem & maturity

yyjson is mature and widely packaged. Distribution is maximally friction-free — **a single `src/yyjson.h` + `src/yyjson.c`** dropped into any project, with compile-time `YYJSON_DISABLE_*` switches that, e.g., cut binary size "by about 60%" when the reader is disabled ([`src/yyjson.h`][hdr]). It is MIT-licensed, tracked across distros (the [`README`][repo] carries a Repology packaging badge), and documented via Doxygen plus in-repo [`doc/API.md`][api], [`doc/DataStructure.md`][ds], and [`doc/BuildAndTest.md`][build]. As a plain-C library with no C++/padding contract, it is a common "fast DOM" choice for projects and language bindings that want simdjson-class speed without simdjson's C++ toolchain or the On-Demand usage contract. Feature breadth beyond raw parsing — JSON5, JSON Pointer/Patch/Merge-Patch, incremental reads, custom allocators, freestanding builds — makes it a full JSON toolkit rather than a parse-only kernel.

---

## Strengths

- **SIMD-class throughput from portable scalar C** — GB/s parse/stringify on any C89 compiler, no intrinsics, no runtime CPU dispatch, embeddable down to freestanding targets.
- **Single-allocation contiguous document** — one `malloc` for a cache-friendly `yyjson_val` array plus one string pool; pointer-free container traversal.
- **Own correctly-rounded number reader/writer** — tiered fast paths (unrolled integer loop, Eisel-Lemire-style multiply) with a bigint slow path and Schubfach output; exact `int64`/`uint64`/`double` without libc on the hot path.
- **Caller-friendly padding** — no mandatory input padding (yyjson copies + pads internally), with an opt-in zero-copy `INSITU` mode for those who want simdjson-style buffer reuse.
- **Genuine JSON toolkit** — strict RFC 8259 plus opt-in JSON5, JSON Pointer/Patch/Merge-Patch, incremental reader, custom allocators, and mutable editing.
- **Trivial integration** — one `.h` + one `.c`, MIT, with size-reducing disable switches.

## Weaknesses

- **One grammar only.** Not a parsing toolkit — you cannot express another language. (By design, as with [simdjson][simdjson].)
- **No error recovery, no incremental reparse, no IDE diagnostics.** First-error-and-stop with a byte position; wrong tool for editors/LSPs.
- **Index/key access is not O(1).** Containers are stored linked-list-style, so random `arr[i]` / `obj[key]` lookups are slower than iterating — the [`README`][repo] flags this explicitly; idiomatic code must iterate.
- **Read/modify split.** Editing requires a `yyjson_mut_doc` copy of an immutable read result — extra allocation and a second representation.
- **Always materializes the whole document.** No lazy On-Demand equivalent; selective "read one field" workloads that favor [simdjson][simdjson]'s iterator have no yyjson analogue.
- **Performance docs are thin.** [`doc/Performance.md`][perf] is a `TODO` stub and the [`README`][repo] charts are dated (2020-12-12), DOM-only benchmarks.

## Key design decisions and trade-offs

| Decision                                                                              | Rationale                                                                                           | Trade-off                                                                                                         |
| ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **No explicit SIMD; scalar branch-tuned C**                                           | Portability to any C89 target, no runtime dispatch, small single-file drop-in; still GB/s           | Leaves per-byte data-parallel headroom on the table vs [simdjson][simdjson]/[`sonic-rs`][sonic-rs] on some inputs |
| **Single-allocation contiguous `yyjson_val` arena + string pool**                     | One `malloc`, cache-friendly, pointer-free traversal; sized by a 6-/16-byte-per-value estimate      | Container index/key access is O(n)-ish (linked-list-style), not O(1); estimate miss → geometric realloc           |
| **Type + size packed into a 64-bit `tag`**                                            | 16-byte value cell; safe because addresses are < 56 bits on real hardware                           | Size capped at 56 bits; the packed encoding is "private" and must go through the API                              |
| **Hand-written tiered number reader/writer** (unrolled loop, Eisel-Lemire, Schubfach) | Correctly-rounded `int64`/`uint64`/`double` without libc on the hot path; branch-predictor-friendly | Substantial, intricate scalar code (bigint slow path) to maintain and get exactly right                           |
| **Copy + pad input by default, `INSITU` to opt out**                                  | No caller padding contract (unlike simdjson); ergonomic default                                     | Default pays one input copy; zero-copy requires caller-managed padding + buffer lifetime                          |
| **Immutable read, separate mutable build**                                            | Compact, fast, read-optimized parse result; O(1) list edits on the mutable side                     | Editing needs a `mut_copy` — extra allocation and a second data model                                             |
| **Strict validation, first-error-stop** with byte position                            | Safe, well-specified ingestion; keeps the scalar hot loop simple                                    | No recovery/partial results; unsuitable for editors/LSPs                                                          |
| **Everything materialized (no lazy On-Demand)**                                       | Simple, predictable full-DOM model; stringify and repeated access are cheap                         | No skip-unused-values fast path for selective reads                                                               |
| **One `.h` + one `.c`, compile-time disable switches**                                | Trivial vendoring; ~60% smaller without the reader                                                  | Feature toggling is via macros, not modular linkage                                                               |

---

## Sources

- [`ibireme/yyjson` — GitHub repository][repo] (pinned commit `12797c6`) · [`LICENSE`][license] (MIT) · [Doxygen docs][doxy]
- [`README.md` — Features, Limitations, Performance tables, sample code][repo]
- [`doc/DataStructure.md` — immutable/mutable `yyjson_val`, contiguous value + string areas, tag layout][ds]
- [`doc/API.md` — full API surface][api] · [`doc/BuildAndTest.md`][build] · [`doc/Performance.md` (stub: `TODO`)][perf]
- [`src/yyjson.h` — read/write flags, error struct, incremental & pointer/patch API, disable switches][hdr]
- [`src/yyjson.c` — three root readers, single-alloc arena, tiered number reader (Eisel-Lemire + bigint), Schubfach writer, internal padding][src]
- Raffaello Giulietti, _The Schubfach way to render doubles_ (2022) — cited by `f64_bin_to_dec` in [`src/yyjson.c`][src]
- Google [`double-conversion`][dbl-conv] — referenced by the double slow path in [`src/yyjson.c`][src]
- Related: [umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison] · the SIMD siblings [simdjson][simdjson] · [`simd-json`][simd-json] · [`sonic-rs`][sonic-rs] · the scalar predecessor [`rapidjson`][rapidjson] · [`hyperscan`][hyperscan] · [`tree-sitter`][tree-sitter] · [formal languages][formal] · [PEG & packrat][peg]

<!-- References -->

[repo]: https://github.com/ibireme/yyjson
[license]: https://github.com/ibireme/yyjson/blob/master/LICENSE
[doxy]: https://ibireme.github.io/yyjson/doc/doxygen/html/
[api]: https://github.com/ibireme/yyjson/blob/master/doc/API.md
[ds]: https://github.com/ibireme/yyjson/blob/master/doc/DataStructure.md
[build]: https://github.com/ibireme/yyjson/blob/master/doc/BuildAndTest.md
[perf]: https://github.com/ibireme/yyjson/blob/master/doc/Performance.md
[hdr]: https://github.com/ibireme/yyjson/blob/master/src/yyjson.h
[src]: https://github.com/ibireme/yyjson/blob/master/src/yyjson.c
[bench]: https://github.com/ibireme/yyjson_benchmark
[dbl-conv]: https://github.com/google/double-conversion
[json5]: https://json5.org
[rfc6901]: https://datatracker.ietf.org/doc/html/rfc6901
[rfc6902]: https://datatracker.ietf.org/doc/html/rfc6902
[rfc7386]: https://datatracker.ietf.org/doc/html/rfc7386
[simdjson]: ./simdjson.md
[simd-json]: ./simd-json.md
[sonic-rs]: ./sonic-rs.md
[rapidjson]: ./rapidjson.md
[hyperscan]: ./hyperscan.md
[tree-sitter]: ./tree-sitter.md
[formal]: ./theory/formal-languages.md
[peg]: ./theory/peg-packrat.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
