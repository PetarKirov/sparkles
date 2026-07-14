# simd-json (Rust)

A near-line-by-line Rust port of [simdjson][simdjson]'s classic two-stage pipeline — the same branchless SIMD structural indexer feeding a tape-building state machine — re-shaped to fit the Rust ecosystem: `serde` compatibility, borrowed/owned DOM values, and a mutable-in-place input contract. "_Rust port of extremely fast simdjson JSON parser with Serde compatibility._" ([`README.md`][repo-readme])

| Field                     | Value                                                                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Language                  | Rust (edition 2024; MSRV `rust-version = "1.88"`)                                                                              |
| License                   | Apache-2.0 OR MIT (dual — same as [simdjson][simdjson])                                                                        |
| Repository                | [`simd-lite/simd-json`][repo] (pinned SHA `0662a83`, 2026-03-11; crate `0.17.0`)                                               |
| Documentation             | [simd-json.rs][site] · [docs.rs/simd-json][docsrs] · [`README.md`][repo-readme]                                                |
| Key authors               | Heinz N. Gies, Sunny Gleason, and contributors                                                                                 |
| Category                  | SIMD / data-parallel scanner-validator + tape/DOM builder (Rust)                                                               |
| Algorithm / grammar class | Two-stage SIMD: vectorized **structural indexing** (stage 1) + a `goto` state machine building a **tape** (stage 2); RFC 8259  |
| Performance posture       | Tracks the C++ implementation ("currently tracking `0.2.x`"); DOM/tape ergonomics prioritized over raw throughput in places    |
| Zero-copy / alloc model   | Borrows `&'input str` into the (mutated) input buffer; de-escapes **in situ**; reusable `Buffers`; no lazy On-Demand front-end |
| SIMD dispatch             | Runtime feature detection on x86 (AVX2 / SSE4.2), NEON on `aarch64`, SIMD128 on `wasm`, scalar Rust `Native` fallback          |

> [!NOTE]
> simd-json is not a parser _generator_ or combinator library — like [simdjson][simdjson] it parses exactly one grammar (JSON, plus a serde path). Its interest to this survey is as the **Rust incarnation of SIMD / data-parallel parsing**: the same [carry-less-multiply / `pshufb` machinery][simdjson] the [C++ original][simdjson] pioneered, re-expressed under Rust's ownership model and `unsafe` discipline. Read it against [simdjson][simdjson] (what the port keeps vs changes), against the Rust-ecosystem [combinator][nom] design point ([`nom`][nom]), and against the other SIMD siblings [`sonic-rs`][sonic-rs], [`yyjson`][yyjson], and [`rapidjson`][rapidjson] in the [comparison][comparison].

---

## Overview

### What it solves

simd-json exists to bring simdjson's "_parsing gigabytes of JSON per second_" to Rust without dropping to FFI. The [`README`][repo-readme] states the design stance plainly:

> _"simd-json is a Rust port of the simdjson c++ library. It follows most of the design closely with a few exceptions to make it better fit into the Rust ecosystem."_
> — [`README.md`][repo-readme]

And the goal is explicitly _not_ a transliteration:

> _"The goal of the Rust port of simdjson is not to create a one-to-one copy, but to integrate the principles of the C++ library into a Rust library that plays well with the Rust ecosystem. As such we provide both compatibility with Serde as well as parsing to a DOM to manipulate data."_
> — [`README.md`][repo-readme]

The two "exceptions to make it better fit Rust" that dominate the design are (1) **first-class `serde` integration** — drop-in `from_slice` / `from_str` mirroring `serde_json` — and (2) **owned _and_ borrowed DOM values** that behave like idiomatic Rust containers (`HashMap`/`Vec`-like), rather than simdjson's `string_view`-over-tape model. Everything mechanical below the DOM — stage 1 structural indexing, the tape, number/string parsing — is a faithful port of simdjson's **classic** path.

### Design philosophy

Three ideas, all inherited from [simdjson][simdjson] but re-cast in Rust:

1. **Port the branchless stage 1 verbatim.** simd-json's `Stage1Parse` trait ([`lib.rs`][lib]) carries simdjson's C++ comments _word for word_ — including "_right shift of a signed value expected to be well-defined and standard compliant as of C++20 … John Regher from Utah U. says this is fine code_" ([`lib.rs`][lib], `find_quote_mask_and_bits`). The algorithm is not reinvented; it is transcribed and made to pass Rust's borrow checker with heavy `unsafe`.

2. **Fit Rust's ownership model, even at a cost.** The [`README`][repo-readme] is candid that the port sometimes trades speed for ergonomics: "_in some design decisions—such as parsing to a DOM or a tape—ergonomics is prioritized over performance. In other places Rust makes it harder to achieve the same level of performance._"

3. **Own the `unsafe`, then fence it in.** Unlike simdjson (where `unsafe` is invisible in C++), Rust forces every SIMD intrinsic and unchecked access to be marked. The [`README`][repo-readme] leads with it: "_`simd-json` uses **a lot** of unsafe code_" — SIMD intrinsics are "_inherently unsafe … inescapable_", plus deliberate bypasses of "_performance bottlenecks imposed by safe rust_" — and answers with layered testing (unit, constructive & destructive property-based, fuzzing against upstream corpora).

The sharpest departure from modern simdjson is what simd-json _does not_ have: it tracks simdjson's **`0.2.x`** era, which predates [**On Demand**][simdjson]. There is no lazy iterator front-end — stage 2 always runs and always materializes a full tape. simd-json's answer to "don't pay for what you don't read" is instead a [`lazy::Value`](#lazy-value-the-nearest-thing-to-on-demand) that sits on the finished tape (see below), not an iterator that skips building it.

---

## How it works

simd-json parses in **two passes**, exactly as [simdjson][simdjson] does ([`lib.rs`][lib], `find_structural_bits` → `build_tape`):

| Stage       | Input → Output                             | Mechanism                                                                                                          |
| ----------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| **Stage 1** | `&[u8]` → `Vec<u32>` of structural indexes | branchless SIMD over 64-byte chunks: backslash/quote masking, `shufti` classification, `simdutf8` UTF-8 validation |
| **Stage 2** | indexes + input → `Vec<Node>` tape         | a `goto`/state-machine walk (`build_tape`) that parses numbers, strings, atoms and emits tape `Node`s              |

### Stage 1 — the ported structural indexer

The `Stage1Parse` trait ([`lib.rs:149`][lib]) is the port's spine, and its default methods are simdjson's stage-1 kernels rewritten in safe-looking Rust wrapping `unsafe` intrinsics:

- **`find_odd_backslash_sequences`** — the odd/even backslash-run carry trick, using `EVEN_BITS = 0x5555_5555_5555_5555`, `wrapping_add`, and `overflowing_add` to propagate the carry-out across the 64-bit boundary ([`lib.rs`][lib]). This is simdjson's escaped-quote preamble, bit-for-bit.
- **`find_quote_mask_and_bits`** — computes the in-string mask by `compute_quote_mask(quote_bits)` (the **carry-less multiply** — simdjson's `prefix_xor`/`pclmulqdq`) then `^= prev_iter_inside_quote`; the cross-block carry is `static_cast_i64!(quote_mask) >> 63`, the same arithmetic-right-shift-of-the-top-bit propagation simdjson uses. It also folds in unescaped-control-character error detection (`unsigned_lteq_against_input(0x1F)`). The kernel is a direct transcription — even the C++ provenance comment survives ([`lib.rs`][lib]):

  ```rust
  let mut quote_mask: u64 = Self::compute_quote_mask(*quote_bits);
  quote_mask ^= *prev_iter_inside_quote;
  // ... characters that MUST be escaped: quotation mark, reverse solidus,
  // and the control characters (U+0000 through U+001F). https://tools.ietf.org/html/rfc8259
  let unescaped: u64 = self.unsigned_lteq_against_input(Self::fill_s8(0x1F));
  *error_mask |= quote_mask & unescaped;
  // right shift of a signed value expected to be well-defined and standard
  // compliant as of C++20, John Regher from Utah U. says this is fine code
  *prev_iter_inside_quote = static_cast_u64!(static_cast_i64!(quote_mask) >> 63);
  ```

- **`find_whitespace_and_structurals`** — the per-arch `shufti`. The AVX2 implementation ([`impls/avx2/stage1.rs`][avx2-stage1]) does "_a 'shufti' to detect structural JSON characters_" with `_mm256_shuffle_epi8` (the `vpshufb` nibble table lookup), `structural_shufti_mask = 0x7`, `whitespace_shufti_mask = 0x18` — simdjson's vectorized classification, transliterated.
- **`finalize_structurals`** — masks quote interiors out and adds **pseudo-structural characters** (non-whitespace outside quotes that follow whitespace/structure), the marker that lets stage 2 stop atoms at their first byte. Comment and logic match simdjson.
- **`flatten_bits`** — the unconditional bit-to-index extraction that overwrites surplus indexes on the next iteration to dodge a mispredicted branch.

The driver loop `_find_structural_bits` ([`lib.rs:883`][lib]) walks the input in `SIMDINPUT_LENGTH = 64`-byte chunks, feeds each chunk to the UTF-8 validator, then runs the five kernels above. Two notable Rust-specific details: it pads the input into an `AlignedBuf` (SIMD-aligned allocation aligned to `SIMDJSON_PADDING = 32`, "_upper limit `mem::size_of::<__m256i>()`_") plus a trailing 64-byte zero region so the wide loads can overrun safely, and it carries an extra end-of-input check absent upstream — "_This test isn't in upstream … if `prev_iter_inside_quote != 0` → `Err(Syntax)`_" ([`lib.rs`][lib]).

### UTF-8 validation — delegated to `simdutf8`

Where simdjson ships its own [three-`pshufb` Lookup validator][simdjson], simd-json **delegates UTF-8 validation to the [`simdutf8`][simdutf8] crate** via its `ChunkedUtf8Validator` trait ([`lib.rs`][lib]: `use simdutf8::basic::imp::ChunkedUtf8Validator`). `simdutf8` is itself a Rust port of the same Keiser–Lemire "less than one instruction per byte" algorithm, so the validation _algorithm_ is shared with simdjson even though the _code_ is a separate crate. The scalar `Native` fallback has no chunked validator, so it "_validate[s] UTF8 ahead of time_" with `core::str::from_utf8` before running stage 1 ([`lib.rs`][lib]).

### Stage 2 — the tape

Stage 2 (`build_tape` in [`stage2.rs`][stage2]) walks the structural index with an explicit `StackState` stack and a `State` enum (`ObjectKey`, …), validating atoms with word-at-a-time tricks — `is_valid_true_atom` reads 8 bytes as a `u64` and XORs against `0x00_00_00_00_65_75_72_74` (`"true"`), same as simdjson ([`stage2.rs`][stage2]). It emits a flat `Vec<Node>` **tape**. A `Node` ([`value/tape.rs`][tape]) is a Rust enum, not a 64-bit word:

```rust
pub enum Node<'input> {
    String(&'input str),
    Object { len: usize, count: usize },
    Array  { len: usize, count: usize },
    Static(StaticNode),   // null / bool / i64 / u64 / f64
}
```

The `Object`/`Array` variants carry both `len` (element/key count) and `count` (total nodes in the subtree, **including** nested children) — the same "skip a whole subtree in O(1)" navigation annotation as simdjson's tape, expressed as a struct field instead of a packed offset. `Node::String` borrows `&'input str` directly out of the input buffer.

### Values API — borrowed vs owned

On top of the tape sit two DOM value types ([`value.rs`][value]):

- **`BorrowedValue`** (`to_borrowed_value`) — strings are `&'input str` / `Cow` borrowed from the input; objects are a [`halfbrown::HashMap`][halfbrown] (a small-map-optimized map). The module doc is precise about the zero-copy caveat: "_since JSON strings allow for escape sequences the borrowed value does not implement zero copy parsing, it does however not allocate new memory for strings … using in situ parsing strategies wherever possible_" ([`value.rs`][value]). This is the crux of the [mutable-input requirement](#the-mutable-input-contract): escaped strings are de-escaped **in place inside the caller's buffer**, so the value can borrow the rewritten bytes.
- **`OwnedValue`** (`to_owned_value`) — allocates a fresh `String` per string and carries no lifetime, "_for times when lifetimes are to be avoided_" ([`value.rs`][value]).

Both are built by re-walking the tape (`BorrowDeserializer` / `owned` deserializer), so they are a layer _above_ the tape, not an alternative to it.

### Lazy value — the nearest thing to On Demand

The closest analogue to simdjson's [On Demand][simdjson] is [`value::lazy::Value`][lazy] — but the mechanism is different. It wraps an **already-built tape** and stays a cheap tape view until the first mutation, at which point it "_upgrade[s] to a borrowed value_" ([`value/lazy.rs`][lazy]):

```rust
pub enum Value<'borrow, 'tape, 'input> {
    Tape(tape::Value<'tape, 'input>),           // cheap, read-only
    Value(Cow<'borrow, borrowed::Value<'input>>) // upgraded on mutation
}
```

Crucially this does **not** avoid stage 2 — the tape is fully built first (`to_tape`), and `lazy::Value` merely defers the _DOM materialization_. simdjson's On Demand, by contrast, skips the tape entirely and iterates the structural index directly. The port has no equivalent to that iterator front-end.

The three entry points map onto the three usage styles the [`README`][repo-readme] documents — the tape one exercising the flat `Node` array directly:

```rust
let mut d = br#"{"the_answer": 42}"#.to_vec();   // note: mutable
let tape = simd_json::to_tape(&mut d).unwrap();
let value = tape.as_value();
assert!(value.try_get("the_answer").unwrap().unwrap() == 42);  // treat as object
assert!(value.try_get("does_not_exist").unwrap() == None);      // key absent
assert!(value.try_get_idx(0).is_err());                         // not an array
```

### The mutable-input contract

The single most visible API difference from simdjson: **the input must be a mutable `&mut [u8]`**. Every entry point takes it — `Deserializer::from_slice(input: &'de mut [u8])`, `to_tape(s: &mut [u8])`, `to_borrowed_value(&mut d)` ([`lib.rs`][lib], [`value.rs`][value]). The [`README`][repo-readme] examples all begin `let mut d = br#"..."#.to_vec();`. The reason is the in-situ de-escaping above: simd-json rewrites escape sequences within the buffer so borrowed strings can point at decoded bytes without a separate allocation. simdjson, in contrast, **never modifies its input** ("_it has no insitu mode_" — [simdjson][simdjson]) and pads via a `padded_string`. This makes simd-json awkward for `mmap`-ed or shared read-only buffers, and is the API cost of its no-extra-allocation borrowed strings.

### Reusable buffers

To amortize allocation across many parses, the working set is bundled in a `Buffers` struct ([`lib.rs`][lib]) — `string_buffer`, `structural_indexes`, `input_buffer` (the `AlignedBuf`), and `stage2_stack` — reusable via `to_tape_with_buffers` / `from_slice_with_buffers` / `fill_tape`. This is the port's answer to simdjson's `parser` object holding its scratch across `iterate` calls.

### Runtime CPU dispatch

simd-json selects the fastest kernel at runtime, but via a different mechanism than simdjson's compile-every-kernel-then-pick model. With the default `runtime-detection` feature on x86, the hot functions cache a resolved function pointer in an `AtomicPtr` ("_inspired from simdutf8's implementation_" — [`lib.rs`][lib]): `parse_str_` and `find_structural_bits` start pointing at a `get_fastest` thunk that calls `std::is_x86_feature_detected!("avx2")` / `("sse4.2")`, stores the winner, and dispatches ([`lib.rs`][lib]). The supported set is narrower than simdjson's:

| `Implementation` | Target                 | Notes                                                                                   |
| ---------------- | ---------------------- | --------------------------------------------------------------------------------------- |
| `AVX2`           | x86/x86-64 with AVX2   | best x86 kernel — **no AVX-512 / `icelake` kernel**                                     |
| `SSE42`          | x86/x86-64 with SSE4.2 | 128-bit fallback                                                                        |
| `NEON`           | `aarch64`              | always used on ARM64                                                                    |
| `SIMD128`        | `wasm` with `simd128`  | WebAssembly SIMD                                                                        |
| `StdSimd`        | portable `std::simd`   | experimental, nightly-only (`portable` feature)                                         |
| `Native`         | any                    | scalar Rust fallback (the [`README`][repo-readme] warns it is "_significantly slower_") |

Compared to simdjson's kernel roster ([`icelake`, `haswell`, `westmere`, `arm64`, `ppc64`, `lasx`, `lsx`, `fallback`][simdjson]), simd-json has **no AVX-512, no POWER/`ppc64`, and no LoongArch** — but adds a first-class **WebAssembly `simd128`** kernel and an experimental portable-SIMD path.

---

## Algorithm & grammar class

simd-json parses **exactly one grammar — RFC 8259 JSON** (with a serde path onto arbitrary Rust types). Like [simdjson][simdjson], the interesting question is the algorithm, not the formalism (see [formal languages][formal] and the [concepts glossary][concepts]):

- **Stage 1 is regular-language work done data-parallel** — string/escape detection, `shufti` character classification, and UTF-8 validation are finite-state computations reformulated as branchless bit/SIMD arithmetic over 64-byte windows (carry-less multiply for quote masking, `pshufb` for classification), transcribed from simdjson.
- **Stage 2 is a hand-written pushdown automaton** — an explicit `StackState` stack + `State` enum in `build_tape`, matching JSON's context-free nesting; not recursive descent, not a generated LR table.

**Ambiguity does not arise** — JSON is unambiguous and every value's type is fixed by its first byte, which stage 2 exploits via the pseudo-structural markers. The parser is strict and validating: it rejects malformed atoms, unescaped control characters (`error_mask` in stage 1), invalid UTF-8, unclosed strings/structures, and overflowing numbers.

## Error handling & recovery

**Fail-fast validation, first error, no recovery** — identical posture to [simdjson][simdjson]. Stage 1 accumulates an `error_mask` for unescaped control characters and returns `Err(ErrorType::Syntax)` once at the end; it also returns `Err(Eof)` when the index is empty and `Err(InvalidUtf8)` from the validator's `finalize` ([`lib.rs`][lib]). Errors are a single `Error` carrying an input index, an optional offending `char`, and an `ErrorType` (`Syntax`, `InvalidUtf8`, `Eof`, `InputTooLarge`, `InvalidNumber`, …) — richer positional detail than simdjson's `error_code`, but still first-error-and-stop. There is **no error recovery, no partial parse, no resynchronization, and no incremental reparse**: a malformed document fails as a whole. For the tolerant, error-recovering end of the design space, see the [comparison][comparison].

## Performance

The [`README`][repo-readme] frames the target as parity with the C++ library rather than a set of headline numbers:

> _"As a rule of thumb this library tries to get as close as possible to the performance of the C++ implementation (currently tracking `0.2.x`, work in progress)."_
> — [`README.md`][repo-readme]

Verifiable performance-relevant facts from the tree:

- **Complexity & passes.** O(n), two linear passes (stage 1 index, stage 2 tape). No backtracking, no memoization — the structural opposite of packrat memoization (see [formal languages][formal]).
- **Number parsing** has a `correct` (default) path that is correctly-rounded via 128-bit mantissa tables (`MANTISSA_128`, `POW10`, `POW10_COMPONENTS` in [`numberparse/correct.rs`][numcorrect] — the Eisel–Lemire fast-float approach simdjson also uses) and an `approx-number-parsing` feature that trades exactness for speed. The default `swar-number-parsing` feature parses **8 digits at once** with SSE multiply-adds (`_mm_maddubs_epi16`/`_mm_madd_epi16`, [`numberparse.rs`][numberparse]) — simdjson's `parse_eight_digits_unrolled`.
- **Allocation model.** Borrowed strings avoid per-string allocation by de-escaping in place; `Buffers` are reusable across parses; the `AlignedBuf` is allocated once and reused. The [`README`][repo-readme] recommends a non-default allocator (snmalloc/mimalloc/jemalloc) "_for best performance_".
- **Tuning knobs** as Cargo features: `known-key` (memoized `fxhash` for hot well-known keys), `128bit` (i128/u128 at a stated performance penalty), `big-int-as-float`, `value-no-dup-keys`, `beef` (leaner `Cow`), `ordered-float`.

> [!WARNING]
> **No benchmark throughput numbers are stated in the repository tree** (README, source) at the pinned SHA — only the "tracks C++ `0.2.x`" positioning. Any GB/s figure must be sourced from external benchmarks (e.g. the project's `benches/`, run locally), not quoted from the docs. This page therefore makes **no throughput claim**; contrast simdjson, whose paper and README publish concrete GB/s figures.

## Ecosystem & maturity

simd-json is a mature, widely-depended-on crate (it underpins the `tremor` event-processing engine, from the same authors, and is a common `serde_json` drop-in accelerator). It is published on [crates.io][crates] with [docs.rs][docsrs] docs and a project site at [simd-json.rs][site]. Safety assurance is unusually explicit for a SIMD library: the [`README`][repo-readme] enumerates unit tests, **constructive** property-based testing (random valid JSON), **data-oriented** and **destructive** property-based testing (illegal byte sequences must not crash), and fuzzing "_based on upstream & jsonorg simd pass/fail cases_". The dependency surface is small and Rust-native: [`simdutf8`][simdutf8] (validation), [`value-trait`][valuetrait] (the shared `Value` trait, also from the authors), [`halfbrown`][halfbrown] (object map), optional `serde`/`serde_json`. There are also third-party FFI bindings to upstream simdjson (`simdjson-rust`), which simd-json is explicitly _not_ — it is a reimplementation, not a binding.

---

## Strengths

- **Faithful SIMD port** — inherits simdjson's branchless stage-1 throughput characteristics (carry-less-multiply quote masking, `pshufb` `shufti` classification, unconditional bit-flattening) without FFI.
- **Idiomatic Rust surface** — `serde` `from_slice`/`from_str` drop-in, plus `BorrowedValue`/`OwnedValue` DOM types that behave like `HashMap`/`Vec`.
- **Borrowed values with no per-string allocation** — in-situ de-escaping lets strings borrow the input even through escape sequences, without prior knowledge of content (a genuine edge over serde's zero-copy, per [`value.rs`][value]).
- **Reusable `Buffers`** amortize allocation across many parses (`from_slice_with_buffers`, `fill_tape`).
- **Broad portability incl. WebAssembly** — AVX2/SSE4.2/NEON/SIMD128 with runtime detection on x86, plus a scalar fallback; a `wasm` `simd128` kernel simdjson lacks.
- **Explicit, heavily-tested `unsafe`** — constructive/destructive property testing and fuzzing against upstream corpora.
- **Rich error positions** — `Error` carries an index and offending character.

## Weaknesses

- **No On Demand / lazy-iterator front-end** — tracks simdjson `0.2.x`; stage 2 always builds the full tape, so it cannot match On-Demand's "skip unread values" wins. `lazy::Value` defers DOM materialization but not tape building.
- **Mutable-input requirement** (`&mut [u8]`) — rewrites the caller's buffer in situ; awkward for `mmap`-ed / shared read-only inputs, unlike simdjson's non-mutating `padded_string`.
- **Narrower SIMD roster** — no AVX-512 (`icelake`), no POWER/`ppc64`, no LoongArch kernels; the scalar `Native` fallback is "_significantly slower_".
- **"_a lot_ of unsafe code"** by the authors' own description — SIMD intrinsics plus deliberate safe-Rust bypasses.
- **One grammar only** — not a parsing toolkit (by design, like simdjson).
- **No error recovery / incremental reparse** — wrong tool for editors or language servers.
- **No published throughput numbers** in-tree; parity with C++ is a stated aim ("work in progress"), not a measured guarantee.

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                    | Trade-off                                                                                     |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **Port simdjson's classic two-stage pipeline** (not On Demand)          | Proven, transcribable branchless algorithm; matches C++ `0.2.x`              | No lazy iterator; always pays stage-2 tape build even for selective reads                     |
| **Require mutable `&mut [u8]` input**, de-escape in situ                | Borrowed strings can point at decoded bytes with no per-string allocation    | Rewrites the caller's buffer; unusable on read-only / `mmap`-ed inputs; differs from simdjson |
| **`serde` `from_slice`/`from_str` as a first-class API**                | Drop-in acceleration for the Rust ecosystem's dominant JSON interface        | Extra surface + `serde`/`serde_json` deps behind a (default) feature                          |
| **Borrowed _and_ owned DOM value types**                                | Lets callers choose lifetime-borrowing speed vs lifetime-free convenience    | Two value implementations + a `value-trait` abstraction to maintain                           |
| **Delegate UTF-8 validation to the `simdutf8` crate**                   | Reuse a maintained, equally-fast Rust port of the Lemire/Keiser validator    | An external dependency in the hot path; scalar fallback must pre-validate with `from_utf8`    |
| **`Node` tape as a Rust enum with `len` + `count`**                     | Type-safe subtree-skip navigation without bit-packing                        | Wider than simdjson's packed 64-bit tape word                                                 |
| **Runtime dispatch via cached `AtomicPtr` function pointer**            | Resolve the best kernel once, then branch-free dispatch (à la `simdutf8`)    | `unsafe` `transmute` of function pointers; x86-only detection path                            |
| **`lazy::Value` (tape view, upgrade-on-mutation)** instead of On Demand | Cheap read-only access + mutability without a second parse                   | Still builds the whole tape first; not a true skip-the-work lazy parser                       |
| **Embrace heavy `unsafe`, fence with property tests + fuzzing**         | SIMD intrinsics are unavoidable; safe-Rust bypasses recover lost performance | Large `unsafe` surface; correctness rests on the test/fuzz harness, not the type system       |
| **Narrower kernel set (AVX2/SSE4.2/NEON/SIMD128), add `wasm`**          | Cover the common targets + WebAssembly with less porting cost                | No AVX-512/POWER/LoongArch; leaves peak x86 throughput on the table vs simdjson's `icelake`   |

---

## Sources

- [`simd-lite/simd-json` — GitHub repository][repo] · [simd-json.rs][site] · [docs.rs/simd-json][docsrs] · [crates.io][crates]
- [`README.md` — "Rust port … with Serde compatibility", Goals, Safety, Features, Usage][repo-readme]
- [`src/lib.rs` — `Stage1Parse` trait, `_find_structural_bits`, runtime dispatch, `Buffers`, `AlignedBuf`, mutable-input entry points][lib]
- [`src/stage2.rs` — `build_tape` state machine, word-at-a-time atom validation][stage2]
- [`src/value/tape.rs` — the `Node` tape enum (`String`/`Object`/`Array`/`Static`)][tape]
- [`src/value.rs` — borrowed vs owned DOM, in-situ de-escape caveat][value]
- [`src/value/lazy.rs` — tape-backed value that upgrades to borrowed on mutation][lazy]
- [`src/impls/avx2/stage1.rs` — the `shufti` classification (`_mm256_shuffle_epi8`)][avx2-stage1]
- [`src/numberparse.rs` / `src/numberparse/correct.rs` — SWAR 8-digit parse, correctly-rounded floats][numberparse]
- [`Cargo.toml` — license (Apache-2.0 OR MIT), MSRV `1.88`, edition 2024, feature flags][cargo]
- The C++ original: [simdjson deep-dive][simdjson] · [`simdjson/simdjson`][simdjson-repo]
- Related: [umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison] · [formal languages][formal] · SIMD siblings [`sonic-rs`][sonic-rs] / [`yyjson`][yyjson] / [`rapidjson`][rapidjson] / [`hyperscan`][hyperscan] · Rust combinator [`nom`][nom]

<!-- References -->

[repo]: https://github.com/simd-lite/simd-json
[repo-readme]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/README.md
[lib]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/src/lib.rs
[stage2]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/src/stage2.rs
[tape]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/src/value/tape.rs
[value]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/src/value.rs
[lazy]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/src/value/lazy.rs
[avx2-stage1]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/src/impls/avx2/stage1.rs
[numberparse]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/src/numberparse.rs
[numcorrect]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/src/numberparse/correct.rs
[cargo]: https://github.com/simd-lite/simd-json/blob/432715360f1e388ae3168ebd27b7e1985d99c663/Cargo.toml
[site]: https://simd-json.rs
[docsrs]: https://docs.rs/simd-json
[crates]: https://crates.io/crates/simd-json
[simdutf8]: https://crates.io/crates/simdutf8
[valuetrait]: https://crates.io/crates/value-trait
[halfbrown]: https://crates.io/crates/halfbrown
[simdjson-repo]: https://github.com/simdjson/simdjson
[simdjson]: ./simdjson.md
[formal]: ./theory/formal-languages.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
[sonic-rs]: ./sonic-rs.md
[yyjson]: ./yyjson.md
[rapidjson]: ./rapidjson.md
[hyperscan]: ./hyperscan.md
[nom]: ./rust-nom.md
