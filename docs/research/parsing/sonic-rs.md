# sonic-rs (Rust)

A SIMD-accelerated JSON library from ByteDance/CloudWeGo whose distinguishing bet is **on-demand parsing**: instead of building a whole-input structural index like [`simdjson`][simdjson] or an eager tape like [`simd-json`][simd-json], it points SIMD kernels only at the work you ask for — skipping over unread containers, whitespace, and strings — and hands back a `LazyValue` that is a borrowed slice of the still-unparsed JSON.

| Field                     | Value                                                                                                                      |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Language                  | Rust (edition 2021; stable Rust — nightly no longer required)                                                              |
| License                   | Apache-2.0 (`Cargo.toml`); vendored notices for the sources it borrows from under `licenses/`                              |
| Repository                | [`cloudwego/sonic-rs`][repo]                                                                                               |
| Documentation             | [docs.rs/sonic-rs][docsrs] · `docs/performance.md` · `docs/serdejson_compatibility.md`                                     |
| Authors                   | Volo Team `<volo@cloudwego.io>` (ByteDance / CloudWeGo)                                                                    |
| Category                  | SIMD / data-parallel (Rust) — targeted-SIMD, lazy on-demand reader + `serde` deserializer                                  |
| Algorithm / grammar class | Scalar recursive-descent skeleton over RFC 8259 JSON, with SIMD kernels bolted onto the hot loops (strings, floats, skips) |
| Error recovery            | None — fail-fast validating parser; `serde_json`-style errors with source position                                         |
| On-demand / lazy model    | `get`/`get_many` by JSON-pointer → `LazyValue` (borrowed raw-JSON slice); `to_array_iter`/`to_object_iter` lazy iterators  |
| Latest release            | `v0.5.9` (`Cargo.toml`)                                                                                                    |

> [!NOTE]
> sonic-rs is not a parser _generator_ or combinator library — it parses exactly one grammar (JSON, plus a streaming `StreamDeserializer`). Its interest to this survey is its **placement in the SIMD design space**: it is the data point for _targeted, on-demand_ SIMD JSON in Rust, deliberately rejecting the whole-input two-stage pipeline that defines [`simdjson`][simdjson] and its Rust port [`simd-json`][simd-json]. Read it against those two, against the tape-building C library [`yyjson`][yyjson], and against the DOM-first [`rapidjson`][rapidjson]; the [capstone comparison][comparison] lines them up.

---

## Overview

### What it solves

sonic-rs targets the same bottleneck as every parser in this category — JSON ingestion at line rate — but for the Rust/`serde` ecosystem, and with a different center of gravity. Its pitch is a superset of `serde_json`'s API plus "blazing performance" on two workloads `serde_json` handles poorly: deserializing straight into Rust structs, and **plucking a few fields out of a large document without parsing the rest**. The [`README`][repo] frames the library as an all-in-one:

> _"A fast Rust JSON library based on SIMD. It has some references to other open-source libraries like [sonic_cpp](https://github.com/bytedance/sonic-cpp), [serde_json](https://github.com/serde-rs/json), [sonic](https://github.com/bytedance/sonic), [simdjson](https://github.com/simdjson/simdjson), [rust-std] … and more."_
> — [`README.md`][repo]

That lineage is the key to reading the project: it is the **Rust member of ByteDance's `sonic` family** — [`sonic-cpp`][soniccpp] (C++) and `sonic` (Go) came first — reusing their SIMD kernels, borrowing `serde_json`'s de/serialization code for compatibility, and pulling float parsing from `rust-std`. The [`Acknowledgement`][repo] is explicit:

> _"We rewrote many SIMD algorithms from sonic-cpp/sonic/simdjson/yyjson for performance. We reused the de/ser codes and modified necessary parts from serde_json to make high compatibility with `serde`. We reused part codes about floating parsing from rust-std to make it more accurate."_

### Design philosophy

Two commitments shape the codebase, and both are departures from `simdjson`:

1. **Targeted SIMD, not whole-input structural indexing.** sonic-rs applies vector instructions surgically to the four spots that dominate a JSON workload, and nowhere else. The [`README` benchmark note][repo] states the design choice outright:

   > _"The main optimization in sonic-rs is the use of SIMD. However, we do not use the two-stage SIMD algorithms from `simd-json`. We primarily use SIMD in the following scenarios: 1. parsing/serialize long JSON strings 2. parsing the fraction of float number 3. Getting a specific elem or field from JSON 4. Skipping white spaces when parsing JSON."_

   There is no stage-1 pass that classifies every byte and emits a structural index; the parser is a conventional recursive-descent walk whose inner loops call into SIMD helpers. This is the structural antithesis of [`simdjson`][simdjson]'s "index the whole document first" model.

2. **Directness — no intermediate representation on the struct path.** Where [`simd-json`][simd-json] parses to a `tape` and then walks the tape into a Rust value, sonic-rs deserializes JSON text straight into the target struct. From the [`README`][repo]:

   > _"Sonic-rs is faster than simd-json because simd-json (Rust) first parses the JSON into a `tape`, then parses the `tape` into a Rust struct. Sonic-rs directly parses the JSON into a Rust struct, and there are no temporary data structures."_

On-demand access is the philosophy taken to its limit: for `get`, the "value" you receive is a `LazyValue` — a borrowed slice of the original JSON text that has been located but not decoded — so the cost of a field lookup is bounded by _skipping_ to it, not by parsing the document.

---

## How it works

sonic-rs has three front-ends over a shared scalar/SIMD `Parser` (`src/parser.rs`): the **`serde` deserializer** (`from_str`/`from_slice` into any `Deserialize` type), the **`Value` DOM** (an arena-backed mutable tree), and the **on-demand `get`/iterator** layer (`src/lazyvalue/`). All three share the same SIMD primitives.

### The four SIMD kernels

| Workload                   | Kernel                                                                                 | Mechanism                                                                                            |
| -------------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Skip whitespace            | `get_nonspace_bits` ([`util/arch/x86_64.rs`][arch-x86])                                | `_mm256_shuffle_epi8` (`pshufb`) classifies 64 bytes as space/non-space → bitmask of non-space       |
| In-string / escape masking | `prefix_xor`, `get_escaped_branchless_u64` ([`arch/x86_64.rs`][arch-x86], `parser.rs`) | carry-less multiply (`_mm_clmulepi64_si128`) for the in-string mask; branchless escape run detection |
| Skip a container           | `skip_container_loop` ([`docs/performance.md`][perf], `parser.rs`)                     | SIMD bracket bitmaps `&! instring`, count `{`/`}` (or `[`/`]`) to find the matching close            |
| Parse float fraction       | `simd_str2int` (`sonic-number`, from [`sonic-cpp`][soniccpp])                          | vectorized ASCII-digit accumulation for ≤16-digit runs; Lemire's algorithm for the `f64`             |

The whitespace and string kernels are literally the `simdjson` tricks re-expressed in Rust. `prefix_xor` is the same four-instruction carry-less multiply that [`simdjson`][simdjson] uses to turn a quote bitmask into an in-string mask ([`arch/x86_64.rs`][arch-x86]):

```rust
pub unsafe fn prefix_xor(bitmask: u64) -> u64 {
    let all_ones = _mm_set1_epi8(-1i8);
    let result = _mm_clmulepi64_si128(_mm_set_epi64x(0, bitmask as i64), all_ones, 0);
    _mm_cvtsi128_si64(result) as u64
}
```

and `get_escaped_branchless_u64` is the odd-/even-backslash-run computation from `simdjson`, marked as such in `docs/performance.md`: _"This SIMD branchless algorithm is borrowed from simdjson, implemented in `get_escaped_branchless_u64`."_ The difference from `simdjson` is _where_ they run: not over the whole input, but inside `skip_space`, `skip_string`, and `skip_container` — only when the parser actually needs to move past something.

### On-demand `get` by JSON-pointer

The headline feature. `get(json, path)` walks a JSON-pointer path and returns the located sub-value as a `LazyValue` without decoding it ([`README`][repo]):

```rust
let path = pointer!["a", "b", "c", 1];
let json = r#"{"u": 123, "a": {"b" : {"c": [null, "found"]}}}"#;
let target = unsafe { get_unchecked(json, &path).unwrap() };
assert_eq!(target.as_raw_str(), r#""found""#);   // still raw JSON text
assert_eq!(target.as_str().unwrap(), "found");    // decoded only on demand
```

A `LazyValue` "_wrappers an unparsed raw JSON text … borrowed from the origin JSON text_" ([`lazyvalue/value.rs`][lazyvalue]). The traversal (`get_from_object` / `get_from_array`, `src/parser.rs`) is where the SIMD skips earn their keep. In the **unchecked** fast path, once a key mismatches, the parser skips its value wholesale — a container via the SIMD `skip_container`, a string via `skip_string_unchecked`, then jumps to the next `"` or `}` with `get_next_token`:

```rust
// skip object,array,string at first (unchecked fast path)
match self.skip_space() {
    Some(b'{') => self.skip_container(b'{', b'}')?,
    Some(b'[') => self.skip_container(b'[', b']')?,
    Some(b'"') => unsafe { let _ = self.skip_string_unchecked()?; },
    None => return perr!(self, EofWhileParsing),
    _ => {}
};
// optimize: direct find the next quote of key or object ending
match self.get_next_token([b'"', b'}'], 1) { /* … */ }
```

`skip_container` is the SIMD core: `skip_container_loop` loads 64-byte blocks, computes the in-string bitmap, masks the bracket bitmaps with `&! instring`, and counts brackets to find the balance point — so `{ "key": "value {}" }` skips correctly despite the braces inside the string. `docs/performance.md` credits the [JSONSki paper][jsonski] for the bit-parallel container skip. `get_many(json, &PointerTree)` extends this to fetch several pointers in one traversal (`get_many_rec`, `src/parser.rs`).

The **checked** path (`get`, no `unsafe`) does the same skips but fully validates each skipped value with `skip_one(true)` — the safety/speed knob discussed under [Error handling](#error-handling--recovery).

### The `serde` deserializer path

`from_str`/`from_slice` route through `from_trait` (`src/serde/de.rs`), which drives the recursive-descent `Parser` straight into the caller's `Deserialize` impl — no tape, no DOM. UTF-8 is validated by the `simdutf8` crate: `from_slice` validates (checked), while `from_str`/`from_slice_unchecked` trust their input; a final `check_utf8_final()` runs after parse. There is a hard **4 GB ceiling** ("_parsing JSON larger than 4 GB is not supported_", `from_trait`) because `Value` node offsets are 32-bit.

### The `Value` DOM — arena, not node-graph

`sonic_rs::Value` is a mutable untyped document backed by a **`bumpalo` bump arena**, borrowed from `sonic-cpp`/`rapidjson`'s pool idea ([`docs/performance.md`][perf]):

> _"we also use the `bump` crate in sonic-rs to preallocate memory for the entire document. Arena allocation can reduce memory allocation overhead and make the cache more friendly since the memory locations of nodes in the document are adjacent."_

Two more DOM tricks: the node vector is pre-sized to `json.len() / 2 + 2` (the maximum node count of valid JSON) so it never reallocates mid-parse, and a JSON **object is stored as an array, not a hashmap** — "_Sonic-rs does not build a hashmap_" ([`README`][repo]) — trading O(1) key lookup for cache-friendly construction and mutation.

### Number handling

`Number` is the untyped numeric type; `RawNumber` preserves numbers **losslessly** as their original text, "_like `encoding/json.Number` in Golang_" ([`README`][repo]), and can even be parsed from a JSON string. Float parsing defaults to Rust-std precision (correctly rounded) via Lemire's algorithm in the `sonic-number` sub-crate — no `float_roundtrip`-style opt-in is needed, unlike `serde_json`.

### `serde_json` drop-in compatibility

sonic-rs re-exports `Deserialize`/`Serialize` from `serde` and mirrors `serde_json`'s free functions (`from_str`, `from_slice`, `to_string`, `to_vec`, …). The migration guide (`docs/serdejson_compatibility.md`) is a four-line type map:

| `serde_json`                | `sonic_rs`                 |
| --------------------------- | -------------------------- |
| `&serde_json::RawValue`     | `sonic_rs::LazyValue<'a>`  |
| `Box<serde_json::RawValue>` | `sonic_rs::OwnedLazyValue` |
| `serde_json::Value`         | `sonic_rs::Value`          |
| `serde_json::RawNumber`     | `sonic_rs::RawNumber`      |

with one documented semantic difference — `sonic_rs::Value` differs from `serde_json::Value` "_when JSON has duplicate keys_" (object-as-array keeps duplicates rather than collapsing them).

---

## Algorithm & grammar class

sonic-rs parses **exactly one grammar — RFC 8259 JSON** (plus newline-independent streaming via `StreamDeserializer`); there is no grammar input. On the algorithm axis it sits between the pure-scalar recursive-descent parsers and the whole-input SIMD parsers:

- **The control structure is ordinary recursive descent** — `parse_object`, `parse_array`, `parse_number`, `parse_string`, `parse_literal` in `src/parser.rs`, a pushdown walk with single-byte lookahead. JSON is `LL(1)`-style: each value's type is fixed by its first byte, so no backtracking or ambiguity arises. This is the same automaton class as [`simdjson`][simdjson]'s _stage 2_, but reached one byte at a time rather than by iterating a precomputed structural index.
- **SIMD appears only inside the leaf loops** — skipping runs of whitespace, scanning to a string's closing quote, balancing a container's brackets, and accumulating a float's digits. These are the finite-state sub-problems reformulated as branchless bit/vector arithmetic (carry-less multiply, `pshufb` classification), exactly the [`simdjson`][simdjson] techniques — but _localized_, so there is no O(n) structural-index array over the whole document.

The consequence is a different cost profile from the two-stage parsers: sonic-rs pays nothing to index bytes it will skip, which is why its on-demand `get` and struct-deserialize numbers lead the field, while its _whole-document untyped_ numbers rely instead on the arena and object-as-array tricks rather than a vectorized front-end.

## Interface & composition model

There is **no grammar DSL, no combinator, no generator** — the surface is JSON-in, values-out, with four host-facing shapes:

| API                | Shape                                                                          | When                                                        |
| ------------------ | ------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| **`serde`**        | `from_str`/`from_slice` → any `Deserialize`; `to_string` ← any `Serialize`     | Drop-in `serde_json` replacement; fastest struct path       |
| **On-demand get**  | `get`/`get_unchecked`/`get_many` by `pointer!` → `LazyValue`/`OwnedLazyValue`  | Pluck a few fields from a large document without full parse |
| **Lazy iterators** | `to_array_iter`/`to_object_iter[_unchecked]` → iterator of `LazyValue`         | Stream over an array/object, decoding elements on demand    |
| **`Value` DOM**    | `from_str` → mutable arena-backed `Value`; `json!` macro; pointer/index access | Random access, mutation, building JSON programmatically     |

Composition is with the **host program** (borrowed `&str`/`FastStr`/`Bytes` in, borrowed `LazyValue` out), not with other parsers — the `LazyValue` returned by `get` borrows from the input buffer, so the buffer must outlive it, and it re-enters the same engine when you later decode or iterate it.

## Performance

The published `docs/` numbers (Intel Xeon Platinum 8260, `twitter`/`citm_catalog`/`canada` corpora) all compare against `simd-json` and `serde_json`:

- **Deserialize into struct.** `twitter`: sonic-rs `from_slice` ~828 µs vs `simd_json` ~1.09 ms vs `serde_json::from_slice` ~2.29 ms; the `_unchecked` variant ~708 µs. sonic-rs leads on all three files, attributed to skipping the `simd-json` tape ([`README`][repo]).
- **Deserialize untyped (`Value`).** `twitter`: `sonic_rs_dom::from_slice` ~556 µs vs `simd_json::slice_to_borrowed_value` ~1.20 ms vs `serde_json::from_slice` ~3.80 ms — credited to the arena, fewer allocations, and object-as-array ([`README`][repo]).
- **Get one field.** `twitter/get_unchecked_from_str` ~77 µs vs `get_from_str` (validated) ~435 µs vs `gjson` ~363 µs — the on-demand advantage, and the sharp cost of turning validation on.
- **Serialize.** Wins on `twitter` (many long strings, favoring the SIMD `copy-and-find` string serializer) and `citm_catalog`; roughly par with `serde_json` on `canada` (mostly floats).
- **Backtracking / memoization.** None — recursive descent with single-byte lookahead; skips are forward-only.
- **Zero-copy.** `LazyValue`/`as_raw_str` borrow from the input; `to_array_iter` streams without materializing the whole array.

> [!WARNING]
> The numbers assume `-C target-cpu=native`. sonic-rs selects its SIMD backend **at compile time** (`cfg_if!` on `target_feature`, `src/util/arch/mod.rs`) — x86-64 needs `pclmulqdq`+`avx2`+`sse2`, aarch64 needs `neon`, else a scalar `fallback` — so a generic build silently drops to the slow path. Runtime CPU detection is still an open `ROADMAP` item, a real difference from [`simdjson`][simdjson]'s runtime dispatch.

## Error handling & recovery

sonic-rs is a **strict, fail-fast validating parser** — no recovery, no partial parse. Errors follow `serde_json`: an `Error`/`ErrorCode` with a source position and a rendered pointer at the failure site (e.g. `"Expected this character to be either a ',' or a ']' while parsing at line 1 column 17"`, from the iterator example in the [`README`][repo]). The `get` API surfaces typed failures — `is_not_found()`, `is_unmatched_type()` — for path lookups.

The distinctive knob is the **checked/unchecked split**, present on every entry point (`from_slice` vs `from_slice_unchecked`, `get` vs `get_unchecked`, `to_object_iter` vs `to_object_iter_unchecked`):

- **Checked** validates UTF-8 (via `simdutf8`) and fully validates every value it skips (`skip_one(true)`), so malformed JSON anywhere is caught.
- **Unchecked** (`unsafe`) trusts the input is valid UTF-8 and well-formed, and uses the SIMD fast-skip that does _not_ re-validate skipped regions — much faster (77 µs vs 435 µs for `get`) but "_may return unexpected result_" on invalid JSON ([`get.rs`][getrs] docs). This is a caller-facing correctness/speed trade-off, not automatic.

There is **no error recovery, no resynchronization, no incremental reparse** — sonic-rs is built for batch ingestion and field extraction, not for editors or language servers. For the tolerant, incremental end of the design space see [`tree-sitter`][treesitter]; the contrast with the strict SIMD parsers is drawn in the [comparison][comparison].

## Ecosystem & maturity

sonic-rs is a production library from **ByteDance's CloudWeGo** org (alongside the `Volo` RPC framework and the Go `sonic`), published on crates.io with docs.rs documentation, CI, codecov, and a `fuzz/` harness. It ships a `for_Golang_user.md` guide (for teams migrating from the Go `sonic`) and Golang/serde compatibility docs. Optional cargo features tune behavior: `arbitrary_precision`, `sort_keys`, `utf8_lossy`, `sanitize` (LLVM-sanitizer false-positive avoidance, ~30% serialize cost), `non_trailing_zero`, and `avx512` (Rust 1.89+). The `sonic-simd` sub-crate is a portable SIMD layer (x86 AVX2/AVX-512, ARM NEON, wasm128, scalar fallback; RIS-V is a TODO).

Its lineage gives it unusual depth of prior art: it inherits algorithms and test corpora from `sonic-cpp`, `sonic` (Go), `simdjson`, `yyjson`, and `serde_json` at once. `ROADMAP.md` lists runtime CPU detection, JSONPath, and JSON Merge Patch (RFC 7396) as future work.

---

## Strengths

- **On-demand `get`/`get_many`** returns a borrowed `LazyValue` without decoding — the fastest way in the Rust ecosystem to pluck fields from a large document (~77 µs vs `gjson` ~363 µs on `twitter`).
- **Direct struct deserialization** with no intermediate tape or DOM — beats [`simd-json`][simd-json] (which walks a tape) and `serde_json` on every struct benchmark.
- **`serde_json` drop-in**: same free functions, re-exported `serde` traits, a four-line type-map migration — adoption cost is near zero.
- **Arena-backed mutable `Value`** with pre-sized node storage and object-as-array — fast untyped parse and cheap in-place mutation.
- **Rust-std float precision by default** (no `float_roundtrip` opt-in), plus lossless `RawNumber` when you need the original text.
- **Reuses battle-tested SIMD kernels** from the `sonic-cpp`/`simdjson`/`yyjson` lineage rather than inventing them.

## Weaknesses

- **No whole-input validation shortcut**: because SIMD is localized, there is no single fast structural pass — the _validated_ (`checked`) paths are markedly slower than the `unchecked` ones, and the fast paths are `unsafe` and trust their input.
- **Compile-time-only SIMD dispatch**: needs `-C target-cpu=native`; a portable binary silently uses the scalar fallback. No runtime CPU detection yet (unlike [`simdjson`][simdjson]).
- **4 GB document ceiling** — `Value` uses 32-bit node offsets, so larger inputs are rejected outright.
- **One grammar only.** Not a parsing toolkit; you cannot express another language. (By design.)
- **No error recovery / incremental reparse / IDE diagnostics** — wrong tool for editors or language servers.
- **`x86_64`/`aarch64` only** for the fast paths; other architectures fall back to scalar and "_maybe very slower_" ([`README`][repo]).
- **`unsafe`-heavy** fast paths and object-duplicate-key semantics that differ subtly from `serde_json::Value`.

## Key design decisions and trade-offs

| Decision                                                                            | Rationale                                                                                | Trade-off                                                                                         |
| ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Targeted SIMD** in four hot loops, _not_ a two-stage whole-input structural index | Pays no cost to index bytes it will skip; wins on struct-deser and field-get             | No single fast validation pass; validated paths are slower; loses `simdjson`'s uniform cost model |
| **On-demand `get` → borrowed `LazyValue`**                                          | Field extraction bounded by skipping, not parsing; zero-copy raw slice                   | `LazyValue` borrows the input (lifetime constraint); re-parses when later decoded                 |
| **Deserialize straight into the struct** (no tape/DOM)                              | Eliminates `simd-json`'s tape→struct second walk                                         | No reusable intermediate; each API re-traverses the text                                          |
| **`checked` vs `unchecked`** on every entry point                                   | Lets callers buy speed with an invariant (valid UTF-8 + well-formed JSON)                | `unchecked` is `unsafe` and returns garbage on invalid input; correctness moved to the caller     |
| **`bumpalo` arena + pre-sized node vec + object-as-array** for `Value`              | Fewer allocations, cache-adjacent nodes, no hashmap build; fast untyped parse & mutation | O(n) key lookup in objects; duplicate-key semantics differ from `serde_json::Value`               |
| **Compile-time SIMD selection** via `cfg_if!` on `target_feature`                   | Zero dispatch overhead in the hot loop; simplest to implement                            | Needs `-C target-cpu=native`; portable builds fall back to scalar; runtime detection still TODO   |
| **Reuse `simdjson`/`sonic-cpp`/`serde_json` code** rather than re-derive            | Proven kernels and high `serde` compatibility, faster to a correct release               | Inherits their constraints (e.g. `simdjson`'s escape/quote tricks, 32-bit offsets)                |
| **Rust-std float precision by default**                                             | Correct rounding without a `float_roundtrip`-style opt-in; `RawNumber` for lossless text | Slightly more work than a fast-but-lossy float path                                               |

---

## Sources

- [`cloudwego/sonic-rs` — GitHub repository][repo] · [docs.rs/sonic-rs][docsrs]
- [`README.md` — SIMD scenarios, benchmarks, `get`/`LazyValue`/`Number` usage, acknowledgements][repo]
- [`docs/performance.md` — on-demand container skip, `skip_space`, SIMD float parse, arena allocator][perf]
- [`docs/serdejson_compatibility.md` — the `serde_json` → `sonic_rs` type map][compat]
- [`src/parser.rs` — recursive-descent core, `get_from_object`/`get_from_array`, `skip_container`, escape masking][getrs]
- [`src/util/arch/x86_64.rs` — `prefix_xor` (`clmul`), `get_nonspace_bits` (`pshufb`)][arch-x86]
- [`src/lazyvalue/value.rs` — `LazyValue` (borrowed raw-JSON wrapper)][lazyvalue]
- Geoff Langdale, Daniel Lemire, [_Parsing Gigabytes of JSON per Second_, VLDB Journal 28(6), 2019][jsonpaper] — the SIMD tricks sonic-rs borrows
- Lin Jiang, Junqiao Qiu, Zhijia Zhao, [_JSONSki: streaming semi-structured data with bit-parallel fast-forwarding_, ASPLOS 2022][jsonski] — the bit-parallel container skip
- [`bytedance/sonic-cpp` — the C++ sibling whose SIMD kernels sonic-rs rewrites][soniccpp]
- Related: [umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison] · [`simdjson`][simdjson] · [`simd-json`][simd-json] · [`yyjson`][yyjson] · [`rapidjson`][rapidjson] · [`hyperscan`][hyperscan] · [formal languages][formal]

<!-- References -->

[repo]: https://github.com/cloudwego/sonic-rs
[docsrs]: https://docs.rs/sonic-rs
[perf]: https://github.com/cloudwego/sonic-rs/blob/03545a9530346fe279b674dd496e037d94204bc5/docs/performance.md
[compat]: https://github.com/cloudwego/sonic-rs/blob/03545a9530346fe279b674dd496e037d94204bc5/docs/serdejson_compatibility.md
[getrs]: https://github.com/cloudwego/sonic-rs/blob/03545a9530346fe279b674dd496e037d94204bc5/src/parser.rs
[arch-x86]: https://github.com/cloudwego/sonic-rs/blob/03545a9530346fe279b674dd496e037d94204bc5/src/util/arch/x86_64.rs
[lazyvalue]: https://github.com/cloudwego/sonic-rs/blob/03545a9530346fe279b674dd496e037d94204bc5/src/lazyvalue/value.rs
[soniccpp]: https://github.com/bytedance/sonic-cpp
[jsonpaper]: https://arxiv.org/abs/1902.08318
[jsonski]: https://dl.acm.org/doi/10.1145/3503222.3507719
[umbrella]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[simdjson]: ./simdjson.md
[simd-json]: ./simd-json.md
[yyjson]: ./yyjson.md
[rapidjson]: ./rapidjson.md
[hyperscan]: ./hyperscan.md
[treesitter]: ./tree-sitter.md
[formal]: ./theory/formal-languages.md
