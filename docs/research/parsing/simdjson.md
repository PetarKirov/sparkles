# simdjson (C++)

A two-stage, SIMD-data-parallel JSON parser and UTF-8 validator that walks the _whole_ input through branchless vector kernels to build a structural index, then serves a lazy [On Demand](#on-demand-vs-dom) API — "[parsing] gigabytes of JSON per second on a single core."

| Field                     | Value                                                                                                                                     |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Language                  | C++ (C++11 minimum; C++17/20/26 paths for ergonomics & reflection)                                                                        |
| License                   | Apache-2.0 OR MIT (dual)                                                                                                                  |
| Repository                | [`simdjson/simdjson`][repo]                                                                                                               |
| Documentation             | [simdjson.org][site] · [`doc/basics.md`][basics] · [Doxygen][doxy]                                                                        |
| Key authors               | Daniel Lemire, Geoff Langdale, John Keiser, and contributors                                                                              |
| Category                  | SIMD / data-parallel scanner-validator + lazy document reader                                                                             |
| Algorithm / grammar class | Two-stage: vectorized **structural indexing** (stage 1) + a `goto` state machine over the index (stage 2); accepts RFC 8259 JSON          |
| Lexing model              | **Scannerless and whole-input data-parallel** — no token stream; stage 1 classifies all 64-byte blocks at once into bitsets, then indexes |
| Latest release            | `v4.6.4` (May 2026)                                                                                                                       |

> [!NOTE]
> simdjson is not a parser _generator_ or a combinator library — it parses exactly one grammar (JSON) and a streaming variant (NDJSON). Its interest to this survey is entirely in **how** it parses: it is the canonical data point for _SIMD / data-parallel parsing_, the antithesis of the character-at-a-time [recursive-descent][top-down] and [table-driven LR][bottom-up] machines that dominate the rest of the catalog. Compare it against the incremental-and-error-recovering [`tree-sitter`][tree-sitter] (the opposite design point: tolerant, character-at-a-time, IDE-grade) in the [capstone comparison][comparison].

---

## Overview

### What it solves

Ingesting JSON is a bottleneck: the paper cites measurements that "big-data applications can spend 80–90% of their time parsing JSON documents" ([Langdale & Lemire 2019][paper-pdf], §1). Conventional JSON parsers proceed by _top-down recursive descent that makes a single pass through the input bytes, doing character-by-character decoding_ ([paper][paper-pdf], §3) — one branch per byte, with the branch predictor mispredicting on the irregular structure of real data. simdjson's thesis is that the bulk of JSON parsing — finding the structural characters, separating string interiors from structure, validating UTF-8 — can be expressed as **branchless arithmetic over wide SIMD registers**, processing 64 bytes per step instead of one.

The headline result, stated in the abstract:

> _"We present the first standard-compliant JSON parser to process gigabytes of data per second on a single core, using commodity processors. We can use a quarter or fewer instructions than a state-of-the-art reference parser like RapidJSON. Unlike other validating parsers, our software (simdjson) makes extensive use of Single Instruction, Multiple Data (SIMD) instructions."_
> — [Langdale & Lemire, _Parsing Gigabytes of JSON per Second_, VLDB Journal 28(6), 2019][paper-pdf]

The [`README`][repo] sharpens this into product-level claims: parse JSON "**4x faster than RapidJSON and 25x faster than JSON for Modern C++**," "**Minify JSON at 6 GB/s, validate UTF-8 at 13 GB/s, NDJSON at 3.5 GB/s**." Crucially, simdjson is a _validating_ parser — it does "Full JSON and UTF-8 validation, lossless parsing" — distinguishing it from selective parsers like Mison that "[do] not attempt to validate the documents" ([paper][paper-pdf], §2).

### Design philosophy

Two ideas, repeated throughout the codebase and papers, drive everything:

1. **Vectorization + branchlessness.** "_Vectorized software tends to use fewer instructions than conventional software. Everything else being equal, code that generates fewer instructions is faster_" and "_SIMD instructions are most likely to be beneficial in a branchless setting_" ([paper][paper-pdf], §1). Where Mison "_loop[s] over the results of their initial SIMD identification of characters_," simdjson uses "_branchless sequences to accomplish similar tasks … We have no such loops in our stage 1: it is essentially branchless, with a fixed cost per input byte_" ([paper][paper-pdf], §3.1).

2. **Minimize data dependency.** Stage 1 finds every interesting position _before_ stage 2 parses any value, so values can be parsed without serial dependence. From [`json_scanner.h`][scanner]:

   > _"To minimize data dependency (a key component of the scanner's speed), it finds these in parallel: in particular, the operator/scalar bit will find plenty of things that are actually part of strings. When we're done, `json_block` will fuse the two together by masking out tokens that are part of a string."_

The modern default front-end, **On Demand**, adds a third idea — _lazy materialization_: only the values you actually read are decoded. simdjson is peer-reviewed (the [2019 VLDB paper][paper-pdf], the [2021 UTF-8 paper][utf8-paper], the [2024 On Demand paper][ondemand-paper]) and battle-tested in production (Node.js, ClickHouse, Meta Velox, Apache Doris — see [Ecosystem & maturity](#ecosystem--maturity)).

---

## How it works

simdjson parses in **two passes over the input**, motivated explicitly by performance ([paper][paper-pdf], §3):

> _"In our experience, most JSON parsers proceed by top-down recursive descent that makes a single pass through the input bytes … We adopt a different strategy, using two distinct passes."_

| Stage       | Input → Output                                       | Mechanism                                                                                                            |
| ----------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Stage 1** | raw bytes → array of `uint32_t` structural indexes   | branchless SIMD over 64-byte blocks: string detection, vectorized classification, UTF-8 validation, index extraction |
| **Stage 2** | structural index + bytes → tape / On Demand iterator | a `goto`-based state machine walks the index; parses numbers, strings, atoms on demand                               |

### Core abstractions

| Concept              | Type / file                                                                             | Role                                                                           |
| -------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Block reader         | `buf_block_reader<STEP_SIZE>` ([`buf_block_reader.h`][indexer-dir])                     | Feeds the input in 64-byte (`STEP_SIZE`) blocks to stage 1                     |
| Wide vector          | `simd8x64<uint8_t>` (per-arch `simd.h`)                                                 | Four 128-bit / two 256-bit / one 512-bit register(s) viewed as 64 lanes        |
| String scanner       | `json_string_scanner` ([`json_string_scanner.h`][string-scanner])                       | Computes the in-string mask via `prefix_xor` (carry-less multiply)             |
| Escape scanner       | `json_escape_scanner` ([`json_escape_scanner.h`][indexer-dir])                          | Finds odd-length backslash runs → which quotes are escaped                     |
| Character classifier | `json_character_block::classify` ([`json_scanner.h`][scanner])                          | `pshufb`-based vectorized classification into structural / whitespace / scalar |
| Block fuser          | `json_block` / `json_scanner::next` ([`json_scanner.h`][scanner])                       | Masks string-interior tokens out of the structural bitset                      |
| Structural indexer   | `json_structural_indexer` ([`json_structural_indexer.h`][indexer-dir])                  | Extracts set bits of the structural bitset into the index array                |
| UTF-8 validator      | `utf8_validator` / `utf8_lookup4_algorithm` ([`utf8_lookup4_algorithm.h`][indexer-dir]) | Three-`pshufb` lookup validation of the whole input                            |
| DOM tape             | `dom::parser`, `dom::document` (`include/simdjson/dom/`)                                | Stage 2 builds a 64-bit-word tape (the classic API)                            |
| On Demand reader     | `ondemand::parser`, `ondemand::document` (`include/simdjson/generic/ondemand/`)         | The default lazy front-end; an iterator over the index                         |
| Runtime kernel       | `implementation` ([`implementation.h`][impl-h])                                         | A CPU-tailored kernel; the active one is chosen at runtime                     |

### Stage 1, step 1 — finding string regions with carry-less multiply

The first problem: structural characters (`[`, `{`, `:`, `,`, …) also appear _inside_ strings, where they are mere data. To mask them out, simdjson must know which bytes are inside a quoted region. The trick is to take the bitset of (unescaped) quote positions and compute its **prefix-XOR**: bit `i` of the result is the XOR of all quote bits up to and including `i`, which is `1` for every position strictly between an opening and a closing quote.

The paper derives that the prefix-XOR is exactly a **carry-less multiplication by an all-ones word** ([paper][paper-pdf], §3.1.1):

> _"This prefix sum can be more efficiently implemented as one instruction by using the carry-less multiplication (implemented with the `pclmulqdq` instruction) of our unescaped quote bit vector by another 64-bit word made entirely of ones. The carry-less multiplication works like the regular integer multiplication, but, as the name suggests, without a carry because it relies on the XOR operation instead of the addition."_

The implementation is four instructions, from [`include/simdjson/haswell/bitmask.h`][bitmask]:

```cpp
//
// Perform a "cumulative bitwise xor," flipping bits each time a 1 is encountered.
//
// For example, prefix_xor(00100100) == 00011100
//
simdjson_inline uint64_t prefix_xor(const uint64_t bitmask) {
  // There should be no such thing with a processor supporting avx2
  // but not clmul.
  __m128i all_ones = _mm_set1_epi8('\xFF');
  __m128i result = _mm_clmulepi64_si128(_mm_set_epi64x(0ULL, bitmask), all_ones, 0);
  return _mm_cvtsi128_si64(result);
}
```

This is consumed by [`json_string_scanner::next`][string-scanner], which first removes _escaped_ quotes, then folds in whether the previous block ended mid-string:

```cpp
const uint64_t backslash = in.eq('\\');
const uint64_t escaped = escape_scanner.next(backslash).escaped;
const uint64_t quote = in.eq('"') & ~escaped;
//
// prefix_xor flips on bits inside the string (and flips off the end quote).
//
// Then we xor with prev_in_string: if we were in a string already, its effect is flipped
// (characters inside strings are outside, and characters outside strings are inside).
//
const uint64_t in_string = prefix_xor(quote) ^ prev_in_string;
```

`prev_in_string` is propagated across blocks by **arithmetic right shift of the top bit** (`int64_t(in_string) >> 63`), so a string spanning a block boundary is handled with no branch. The tricky preamble — deciding which quotes are escaped — is itself branchless: simdjson distinguishes odd- vs even-length backslash runs (an even run is a sequence of escaped backslashes; an odd run escapes the following quote) using shifts, masked additions to generate carries, and bitwise logic ([paper][paper-pdf], §3.1.1, Fig. 3). The carry-less multiply has nontrivial latency (7 cycles on Skylake per the paper), so the surrounding code is arranged to hide it; on architectures without a CLMUL unit, simdjson falls back to a 6-step shift-and-XOR ladder (`mask ^= mask << 1; mask ^= mask << 2; …`, [paper][paper-pdf], Appendix B).

### Stage 1, step 2 — vectorized classification with `pshufb`

Identifying the six structural characters and four legal whitespace characters by direct comparison would be "ten comparisons and accompanying bitwise OR operations" ([paper][paper-pdf], §3.1.2). Instead simdjson uses the `vpshufb` byte-shuffle instruction as a **vectorized 16-entry table lookup**, indexed by the low and high nibble of each byte:

> _"Instead of a comparison, we use the AVX2 `vpshufb` instruction to act as a vectorized table lookup to do a vectorized classification. The `vpshufb` instruction uses the least significant 4 bits of each byte (low nibble) as an index into a 16-byte table. … By doing one lookup, followed by a 4-bit right shift and a second lookup (using a different table), we can separate the characters into one of two categories: structural characters and white-space characters."_ ([paper][paper-pdf], §3.1.2)

One low-nibble lookup, a shift, a high-nibble lookup, and a bitwise AND assign each byte a class bitmask: comma, colon, brace/bracket get distinct bit indices, the two whitespace sets get two more, and `AND`-ing with `0b111` vs `0b11000` recovers "structural" vs "whitespace" — "_with only two `vpshufb` instructions and a few logical instructions … No branching is required_" ([paper][paper-pdf], §3.1.2, Table 1). simdjson then derives **pseudo-structural characters** — non-whitespace bytes outside quotes that follow whitespace or a structural character — which mark the _start_ of every atom (`true`, `false`, `null`, numbers), since "_the legal atoms can all be distinguished from each other by their first character_" ([paper][paper-pdf], §3.1.3). The fuse step ANDs the structural bitset with the complement of the in-string mask, dropping all structure that lives inside strings.

### Stage 1, step 3 — UTF-8 validation in parallel

Because JSON mandates a Unicode encoding (UTF-8 by default), a validating parser must check the encoding of the whole input. simdjson validates UTF-8 over the entire buffer "_as a whole_," not string-by-string ([paper][paper-pdf], §3.1.5): it first tests whether a 64-byte block is pure ASCII (top bit clear in every byte) and skips it if so; otherwise it runs the **Lookup algorithm** of [Keiser & Lemire 2021][utf8-paper]:

> _"In the lookup algorithm, vectorized lookup instructions are called three times: once on the low nibble, once on the high nibble and once on the high nibble of the next byte, using three corresponding 16-byte lookup tables."_
> — [Keiser & Lemire, _Validating UTF-8 In Less Than One Instruction Per Byte_, SPE 51(5), 2021][utf8-paper]

Three `pshufb` table lookups classify continuation-byte structure and detect the forbidden cases (overlong encodings, surrogates, out-of-range lead bytes) with saturated subtraction and byte comparisons, all SIMD and branchless. Errors are accumulated by OR-ing into a running error vector and checked **once at the end** — "_Should any check fail, the error variable will become non-zero. We only check at the end of the processing (once) that the variable is zero_" ([paper][paper-pdf], §3.1.5). The standalone validator hits ~13 GB/s, "more than 10 times" faster than the routines in many languages ([utf8-paper][utf8-paper]).

### Stage 1, step 4 — turning bitsets into indexes

The structural bitset is sparse and irregularly spaced, so simdjson transforms it into an array of integer offsets. It uses `tzcnt` (count trailing zeroes) to read the next set-bit position and `blsr` (`s & (s-1)`) to clear it — but the loop branch on "more bits?" would mispredict per word. The fix is to **extract 8 indexes unconditionally** and overwrite the surplus on the next iteration ([paper][paper-pdf], §3.1.4, Fig. 6):

> _"We employ a technique whereby we extract 8 indexes from our bitset unconditionally, then ignore any indexes that were extracted excessively by means of overwriting those indexes with the next iteration of the index extraction loop … as long as the frequency of our set bits is below 8 bits out of 64 we expect few unpredictable branches."_

### Stage 2 — the tape (DOM) and the state machine

In the classic DOM path, stage 2 iterates the index and runs a `goto`-based state machine, pushing array/object state on a stack ([paper][paper-pdf], §3.2). It emits a **tape**: an array of 64-bit words, one per value, with bracket/brace words annotated with the matching close position so navigation can skip a whole subtree without reading it ([paper][paper-pdf], §3.1, Fig. 2). Numbers and strings are parsed by dedicated functions here, deliberately deferred from stage 1 "_as these tasks are comparatively expensive and difficult to perform unconditionally and cheaply over our entire input_" ([paper][paper-pdf], §3).

Number parsing has its own SIMD fast path: when ≥ 8 fractional digits are present, `parse_eight_digits_unrolled` converts them with `pmaddubsw`/`pmaddwd`/`packusdw` SIMD multiply-adds in ~7 instructions instead of eight scalar loads ([paper][paper-pdf], §3.2.1, Fig. 7). simdjson ships a full **fast float** parser (the `fast_float` algorithm, also extracted as a standalone library) that produces correctly-rounded `double`s — the nearest representable value (within ½ ULP).

### On Demand vs DOM

The default API since simdjson 1.0 is **On Demand**, the subject of the [2024 paper][ondemand-paper]:

> _"A `document` is *not* a fully-parsed JSON value; rather, it is an **iterator** over the JSON text. … since it's just an iterator, it lets you parse values as you use them. And particularly, it lets you *skip* values you do not want to use."_
> — [`doc/basics.md`][basics]

On Demand still runs **stage 1** (it needs the structural index), but replaces the tape-building stage 2 with a forward-only cursor that materializes values lazily. The paper frames it as an API that "_appears to the programmer like a conventional DOM-based approach. However, the underlying implementation is a pointer iterating through the content, only materializing the results (objects, arrays, strings, numbers) lazily_" ([ondemand-paper][ondemand-paper]). It is faster than DOM for two reasons: it skips unused values entirely, and the programmer's requested type drives a type-specialized parser, avoiding "_branch mispredictions related to data type determination_" ([`ondemand_design.md`][ondemand-design]). The cost is discipline — values can be parsed only once, iteration cannot restart, and the input buffer must outlive the document ([`doc/basics.md`][basics]):

```cpp
ondemand::parser parser;
padded_string json = padded_string::load("twitter.json");
ondemand::document doc = parser.iterate(json);   // runs stage 1, returns an iterator
for (auto tweet : doc["statuses"]) {             // only the values you touch get parsed
    uint64_t id = tweet["id"];
    std::string_view text = tweet["text"].get_string();
}
```

Reported On Demand throughput on `twitter.json` is ~3.3–3.6 GiB/s, roughly 1.7× the DOM path (~1.9–2.1 GiB/s), and up to 2.6× for selective "find one field" workloads ([ondemand-paper][ondemand-paper]). The input must be padded (`padded_string` / `SIMDJSON_PADDING` extra bytes) so the SIMD loads can read past the logical end safely.

### Runtime CPU dispatch

simdjson compiles **multiple architecture-specific kernels** into one binary and selects the best at runtime on first use. From [`implementation.h`][impl-h], `get_active_implementation()` is documented as:

> _"The active implementation. Automatically initialized on first use to the most advanced implementation supported by this hardware."_

The [`README`][repo] puts it plainly: "_Selects a CPU-tailored parser at runtime. No configuration needed._" The named kernels ([implementation-selection][impl-select]):

| Kernel     | Targets                               | Vector width / ISA            |
| ---------- | ------------------------------------- | ----------------------------- |
| `icelake`  | Intel Ice Lake+, AMD Zen 4+ (AVX-512) | 512-bit, uses AVX-512 + VBMI2 |
| `haswell`  | Intel Haswell+, AMD Zen+ (AVX2)       | 256-bit AVX2                  |
| `westmere` | x86-64 with SSE4.2 (2010+)            | 128-bit SSE4.2 + PCLMULQDQ    |
| `arm64`    | 64-bit ARMv8-A                        | 128-bit NEON                  |
| `ppc64`    | POWER8/POWER9                         | 128-bit VSX/ALTIVEC           |
| `lasx`     | Loongson LoongArch                    | 256-bit LASX                  |
| `lsx`      | Loongson LoongArch                    | 128-bit LSX                   |
| `fallback` | any 64-bit CPU                        | scalar, no SIMD               |

Each kernel implements the same `implementation` interface — `name()`, `description()`, `required_instruction_sets()`, `supported_by_runtime_system()` — and the dispatcher's `detect_best_supported()` returns "_the most advanced supported implementation for the current host_" or `fallback`. The kernels are built into per-architecture namespaces so the same source (`src/generic/stage1/*.h`) is instantiated once per ISA with different `simd8x64` definitions; `get_available_implementations()` lists them and the active one can be overridden for testing.

---

## Algorithm & grammar class

simdjson parses **exactly one grammar — RFC 8259 JSON** (plus NDJSON for the streaming API). It is _not_ a generic parsing engine; there is no grammar input. The "grammar class" question is therefore about the algorithm, not the formalism:

- **Stage 1 is regular-language territory done data-parallel.** Detecting strings, classifying characters, and validating UTF-8 are all finite-state computations, but rather than run a [DFA][formal-languages] one byte at a time, simdjson reformulates them as **branchless bit/SIMD arithmetic over fixed-width windows** — prefix-XOR via carry-less multiply, `pshufb` table lookups, saturated subtraction. This is the data-parallel-finite-automaton idea (Mytkowicz et al.) applied to JSON.
- **Stage 2 is a hand-written pushdown automaton.** Matching brackets/braces requires a stack (JSON nesting is context-free, not regular), implemented as an explicit stack + `goto` state machine, _not_ recursive descent and _not_ a generated [LR table][bottom-up].

**Ambiguity does not arise** — JSON is an unambiguous, `LL(1)`-style grammar with single-character lookahead disambiguation of atoms. simdjson exploits exactly this: every value's type is decided by its first byte ([paper][paper-pdf], §3.1.3). The parser is strict and validating: it rejects malformed numbers (`012`, `1E+`, `.1`), overflowing floats (`1e309`), invalid UTF-8, and unclosed structures. Integers are exact across the full signed-and-unsigned 64-bit range `[−2^63, 2^64)` (values beyond it fall back to `double`).

## Interface & composition model

There is **no grammar DSL, no combinator, no generator** — the only "interface" is JSON-in, values-out. There are three host-facing APIs:

| API           | Shape                                                        | When                                                      |
| ------------- | ------------------------------------------------------------ | --------------------------------------------------------- |
| **On Demand** | `ondemand::parser` → `document` iterator; lazy, forward-only | Default; fastest for whole-document or selective reads    |
| **DOM**       | `dom::parser` → `dom::element` tree over the tape            | Random access, multiple passes, simplest mental model     |
| **Streaming** | `parser.iterate_many()` / `parse_many()` over NDJSON         | Many small documents / newline-delimited JSON at 3.5 GB/s |

The **AST/CST is built only as much as you ask for**: the DOM tape is a flat, navigation-annotated array (not pointer-chasing nodes); On Demand builds no tree at all, returning typed scalars and lazy `object`/`array` iterators. Modern simdjson adds a **builder/reflection layer** — with C++26 reflection, `to_json(player)` / deserialization works "_without invasive macros or manual mapping_" ([`README`][repo], CppCon 2025). Composition _across_ grammars is out of scope by design: simdjson composes with the host program (zero-copy `string_view`s into the padded input), not with other parsers.

## Performance

This is the entire point, so the published numbers are concrete:

- **Throughput.** Up to and beyond 2 GB/s on six of the benchmark files, peaking at ~3 GB/s on `gsoc-2018` on a 3.4 GHz Skylake ([paper][paper-pdf], §4.5, Fig. 9). README headline figures (newer hardware, On Demand): ~4× RapidJSON, minify 6 GB/s, UTF-8 13 GB/s, NDJSON 3.5 GB/s.
- **Instruction count.** "_On average, simdjson uses about half as many instructions as sajson and RapidJSON_" — 8.3 instructions/byte vs 14.7 (sajson) and 18.7 (RapidJSON) on average ([paper][paper-pdf], §4.4, Table 8).
- **Cost model.** Total cycles ≈ `19·F + 11·S + 0.92·B` on Skylake (F = floats, S = structural+pseudo-structural elements, B = bytes), `R² ≥ 0.99` ([paper][paper-pdf], §4.3). Time splits roughly evenly between stage 1 and stage 2.
- **Time/space complexity.** **O(n)** time, **single forward pass per stage**; space is O(n) for the structural index plus, for DOM, the tape; On Demand is near-O(1) auxiliary beyond the index. simdjson does "_not modify the input bytes: it has no insitu mode_" ([paper][paper-pdf], §4.1) — both stages "_mostly read and write sequentially in memory_," so it stays fast even when the document exceeds CPU cache (1.4 GB/s on an 84 MB file, [paper][paper-pdf], Appendix C).
- **Backtracking / memoization.** **None.** Stage 1 has a fixed cost per byte; stage 2 is a single linear walk with no re-scanning. This is the structural opposite of [PEG/packrat][peg] memoization or general-parser charts.
- **Zero-copy / streaming.** On Demand returns `string_view`s into the (padded) input; `iterate_many` streams NDJSON without materializing all documents. Multithreaded NDJSON exceeds 3 GB/s.
- **SIMD / data-parallelism.** The defining property — see [How it works](#how-it-works). "_At least half of the processing time is directly related to SIMD instructions and branchless processing_" ([paper][paper-pdf], §4.3).

The ablation in Appendix B quantifies each trick: dropping carry-less multiply, naive bit extraction, or naive classification each costs measurable stage-1 cycles per byte (e.g. up to ~20% on `mesh` from losing CLMUL).

## Error handling & recovery

simdjson is a **strict validator, not a recovering parser** — and that is a deliberate finding, not a gap. It reports the _first_ error via an `error_code` (e.g. `UNCLOSED_STRING`, `NUMBER_ERROR`, `UTF8_ERROR`, `INCOMPLETE_ARRAY_OR_OBJECT`) and either returns it (the `simdjson_result<T>` monadic-error style) or, if you ignore it, throws on access. There is **no error recovery, no partial parse, no resynchronization** — a malformed document fails as a whole. The rationale is in the paper's opening: "_a parser that accepts erroneous JSON is both dangerous … and poorly specified_" ([paper][paper-pdf], §1).

Diagnostics are minimal by design: stage 1's branchless kernels detect _that_ an error exists by OR-ing into an accumulator and checking once at the end; pinpointing _where_ requires "_a second pass over the input_" ([paper][paper-pdf], §3.1.5). There is **no incremental reparsing and no IDE-readiness** — simdjson is built for batch ingestion at line rate, not for editing buffers. For the tolerant, error-recovering, incrementally-reparsing end of the design space, see [`tree-sitter`][tree-sitter]; the contrast is one of the sharpest in the [comparison][comparison].

## Ecosystem & maturity

simdjson is exceptionally mature and widely deployed. The [`README`][repo] lists production users including **Node.js** (the JavaScript runtime), **ClickHouse**, **Meta Velox**, **Apache Doris**, **StarRocks**, **Milvus**, **QuestDB**, **GreptimeDB**, **Microsoft FishStore**, **WatermelonDB**, the **Ladybird** browser, and **ada-url**. Distribution is friction-free: a single amalgamated `simdjson.h` + `simdjson.cpp`, plus packages in vcpkg, Conan, apt, Homebrew, and others.

It is **peer-reviewed three times over** — the [2019 VLDB Journal paper][paper-pdf], the [2021 SPE UTF-8 paper][utf8-paper], and the [2024 SPE On Demand paper][ondemand-paper] — and the project says "_Our research appears in venues like VLDB Journal, Software: Practice and Experience_." Tooling: extensive benchmarks, a fuzzing harness, Doxygen docs, and CI across all eight kernels.

Ports and reimplementations are numerous and notable: **`simd-json`** (a Rust port by the Wayfair/`simdjson` Rust community), **`simdjson-go`**, **`pysimdjson`** (Python), and bindings for Ruby, PHP, C#, and more (the [`README`][repo] "Bindings and Ports" section). The two-stage structural-indexing idea has spread to adjacent formats — `simdcsv`, XML structural indexing (`simdxml`) — and the `fast_float` number parser is now a standalone library used by Chromium, Rust, and others.

---

## Strengths

- **Class-leading throughput** with full validation — gigabytes/second on a single core, ~½ the instructions of the next-fastest validating parser.
- **Whole-input data-parallelism**: branchless SIMD over 64-byte blocks turns string detection, classification, and UTF-8 validation into a fixed cost per byte with almost no mispredicted branches.
- **Lazy On Demand front-end** materializes only the values you touch, beating DOM by ~1.7× overall and ~2.6× on selective reads, while looking like an ordinary navigable API.
- **Portable performance**: runtime dispatch across AVX-512 / AVX2 / SSE4.2 / NEON / VSX / LoongArch with a scalar fallback — one binary, best kernel chosen automatically.
- **Zero-copy** `string_view` output, no input mutation, sequential memory access that stays fast past cache size.
- **Strict and standards-compliant** (RFC 8259 + full UTF-8), with a clean monadic `simdjson_result<T>` error API.
- **Single-header drop-in**, broad packaging, and deep production adoption.

## Weaknesses

- **One grammar only.** Not a parsing toolkit — you cannot express another language. (By design.)
- **No error recovery, no incremental reparse, no IDE-grade diagnostics.** First-error-and-stop; locating the error needs a second pass. Wrong tool for an editor or language server.
- **On Demand's usage contract is sharp**: values parse once, iteration is forward-only and cannot restart, keys must be read once, and the padded input must outlive the document — easy to misuse.
- **Padding requirement** (`SIMDJSON_PADDING` extra bytes / `padded_string`) complicates ingesting borrowed or `mmap`-ed buffers.
- **SIMD codebase is hard to modify**: the win comes from carefully latency-tuned, per-architecture branchless kernels; contributing requires real microarchitecture knowledge.
- **64-bit only**; the scalar `fallback` is much slower than the vector kernels.

## Key design decisions and trade-offs

| Decision                                                                                 | Rationale                                                                                               | Trade-off                                                                                           |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Two stages (index all structure, then parse) instead of single-pass recursive descent    | Stage 1 finds every position branchlessly with SIMD; stage 2 parses with no inter-value data dependency | Two passes over the data; an extra O(n) structural-index array                                      |
| Detect string regions via **prefix-XOR = carry-less multiply** (`pclmulqdq`)             | One branchless instruction replaces a per-quote loop                                                    | CLMUL has 7-cycle latency (must be hidden); needs a shift/XOR fallback where unavailable            |
| **`pshufb` vectorized classification** (nibble table lookup) over per-character compares | Two shuffles classify all 6 structural + 4 whitespace chars at once, no branches                        | Class encoding is a puzzle (each set must be uniquely keyed by low+high nibble); only 8 classes fit |
| Validate UTF-8 over the **whole input** (3-`pshufb` Lookup), not per-string              | Amortizes setup; ASCII fast path skips most blocks; < 1 instruction/byte                                | Wasted work on documents that are mostly ASCII strings; error location needs a second pass          |
| **Unconditional 8-index extraction** from the structural bitset                          | Avoids a mispredicted branch per word when bits are sparse                                              | Slightly more work when bits are dense (> 8 per 64); a heuristic, not optimal for all densities     |
| **On Demand lazy iterator** as the default front-end                                     | Skips unused values; type-specialized parsers avoid type-dispatch mispredictions; ~1.7–2.6× over DOM    | Forward-only, parse-once contract; input lifetime constraints; harder to reason about than a tree   |
| **Strict validation, first-error-stop**, no recovery                                     | Accepting malformed JSON is "dangerous and poorly specified"; keeps the hot path branchless             | Useless for editors/LSPs; no partial results; no resynchronization                                  |
| **Compile every kernel, dispatch at runtime**                                            | One portable binary that still runs the best SIMD for the host                                          | Larger binary; the build instantiates the generic source once per ISA                               |
| **Padded input, zero-copy output**, no in-situ mutation                                  | SIMD loads can overrun safely; outputs are `string_view`s into the buffer                               | Caller must provide padding and keep the buffer alive                                               |

---

## Sources

- [`simdjson/simdjson` — GitHub repository][repo] · [simdjson.org][site] · [Doxygen docs][doxy]
- [`doc/basics.md` — On Demand usage and the "document is an iterator" model][basics]
- [`doc/ondemand_design.md` — why On Demand beats DOM (lazy, type-driven)][ondemand-design]
- [`doc/implementation-selection.md` — named kernels and runtime dispatch][impl-select]
- [`include/simdjson/implementation.h` — `implementation` interface, `get_active_implementation()`][impl-h]
- [`include/simdjson/haswell/bitmask.h` — `prefix_xor` via `_mm_clmulepi64_si128`][bitmask]
- [`src/generic/stage1/json_string_scanner.h` — in-string mask, escaped-quote removal][string-scanner]
- [`src/generic/stage1/json_scanner.h` — `classify`, parallel structure/scalar fusion][scanner]
- [`src/generic/stage1/` — escape scanner, structural indexer, UTF-8 Lookup validator][indexer-dir]
- Geoff Langdale, Daniel Lemire, [_Parsing Gigabytes of JSON per Second_, VLDB Journal 28(6), 2019][paper-pdf] ([arXiv:1902.08318][paper-abs])
- John Keiser, Daniel Lemire, [_Validating UTF-8 In Less Than One Instruction Per Byte_, SPE 51(5), 2021][utf8-paper]
- John Keiser, Daniel Lemire, [_On-Demand JSON: A Better Way to Parse Documents?_, SPE 54(6), 2024][ondemand-paper]
- Geoff Langdale, [_Finding quote pairs with carry-less multiply (PCLMULQDQ)_, branchfree.org][branchfree]
- Related: [umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison] · [`tree-sitter`][tree-sitter] · [top-down / recursive descent][top-down] · [bottom-up / LR][bottom-up] · [PEG & packrat][peg] · [formal languages][formal-languages]

<!-- References -->

[repo]: https://github.com/simdjson/simdjson
[site]: https://simdjson.org/
[doxy]: https://simdjson.github.io/simdjson/
[basics]: https://github.com/simdjson/simdjson/blob/master/doc/basics.md
[ondemand-design]: https://github.com/simdjson/simdjson/blob/master/doc/ondemand_design.md
[impl-select]: https://github.com/simdjson/simdjson/blob/master/doc/implementation-selection.md
[impl-h]: https://github.com/simdjson/simdjson/blob/master/include/simdjson/implementation.h
[bitmask]: https://github.com/simdjson/simdjson/blob/master/include/simdjson/haswell/bitmask.h
[string-scanner]: https://github.com/simdjson/simdjson/blob/master/src/generic/stage1/json_string_scanner.h
[scanner]: https://github.com/simdjson/simdjson/blob/master/src/generic/stage1/json_scanner.h
[indexer-dir]: https://github.com/simdjson/simdjson/tree/master/src/generic/stage1
[paper-pdf]: https://arxiv.org/pdf/1902.08318
[paper-abs]: https://arxiv.org/abs/1902.08318
[utf8-paper]: https://arxiv.org/abs/2010.03090
[ondemand-paper]: https://arxiv.org/abs/2312.17149
[branchfree]: https://branchfree.org/2019/03/06/code-fragment-finding-quote-pairs-with-carry-less-multiply-pclmulqdq/
[umbrella]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[tree-sitter]: ./tree-sitter.md
[top-down]: ./theory/top-down.md
[bottom-up]: ./theory/bottom-up.md
[peg]: ./theory/peg-packrat.md
[formal-languages]: ./theory/formal-languages.md
