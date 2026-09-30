# Unicode algorithms (Rust, C, and C++)

A source-grounded survey of SIMD UTF validation/transcoding, terminal width and segmentation, and Unicode normalization relevant to `sparkles.base.text`.

**Last reviewed:** September 30, 2026.

| Metadata                   | Value                                                                                                                                                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Languages                  | Rust; scalar C and C++ baselines                                                                                                                                                                                   |
| Category                   | UTF codecs, Unicode properties, segmentation, width, normalization                                                                                                                                                 |
| Primary repositories       | [`xutf`][xutf-manifest], [`simdutf8`][simdutf8-readme], [`encoding_rs`][encoding-readme], [`simd-normalizer`][normalizer-readme], [`unicode-rs`][seg-lib], [`utf8proc`][utf8proc-readme], [`uni-algo`][uni-readme] |
| Licenses                   | See the [local inventory](#local-clone-inventory) and pinned manifests/licenses                                                                                                                                    |
| Evidence                   | Local source inspection at the listed commits; no performance measurements on this page                                                                                                                            |
| Related Sparkles contracts | [UTF validation][spk-utf8], [terminal width][spk-width], [grapheme iteration][spk-grapheme], [bounded analysis][spk-analysis]                                                                                      |

> [!IMPORTANT]
> SIMD **byte classification** is not SIMD normalization, SIMD segmentation, or SIMD property lookup. The implementation boundaries below distinguish vectorized scans from scalar Unicode state machines. Upstream benchmark numbers and “fastest” statements are not local evidence and are not reproduced as results.

## Overview

### What it solves

The relevant questions are whether another implementation does the same operation, where it actually uses vectors, and which optimization can transfer without changing Sparkles' observable semantics. UTF well-formedness, terminal-cell width, grapheme boundaries, and normalized search units are separate contracts.

[`xutf`][xutf-readme] describes its codec policy explicitly:

> “Decoding never fails: truncated sequences, lone surrogates, garbage in → defined output out.”

That is useful prior art, but not a substitute for Sparkles' strict validator or its malformed-byte-preserving analyzer. [`simdutf8`][simdutf8-readme] states the distinction between its own interfaces:

> “The `basic` API flavor is fastest on valid UTF-8, but only checks for errors after processing the whole byte sequence and does not provide detailed information if the data is not valid UTF-8.”

### Design philosophy

The most transferable pattern is **scan cheap cases in bulk; preserve exact state for the exceptional case**. [`simd-normalizer`][normalizer-readme] is precise about the boundary:

> “Non-passthrough bytes are handled with scalar decode, decompose, CCC sort, and optional recomposition.”

The scalar baselines remain useful for correctness and algorithm comparisons, not as evidence of SIMD. [`utf8proc`][utf8proc-readme] positions itself as a “small, clean C library that provides Unicode normalization, case-folding, and other operations”; [`uni-algo`][uni-readme] emphasizes that it “handles such problems … properly and always according to The Unicode Standard.” Neither quote establishes speed or interchangeability.

## Local clone inventory

All paths below are relative to `REPOS=/home/petar/code/repos`. Existing `rust/xutf` was inspected without updating it. All eight other paths were absent and were cloned with `git clone --depth 1`; no existing checkout was replaced. Dates are commit dates, not release dates. These revisions are the citation and future benchmark inputs, not assertions that their package version strings identify published releases.

| Project                 | Local path                   | Inspected commit                           | Commit date        | License evidence                                                         | Unicode data                                                                         |
| ----------------------- | ---------------------------- | ------------------------------------------ | ------------------ | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `xutf`                  | `rust/xutf`                  | `9bb347af041369a68a4effd1ca85c6d2f9b4e17b` | September 3, 2026  | [MIT][xutf-manifest]                                                     | Width/graphemes/normalization 17; category/script **16 by default**, `ucd-17` opt-in |
| `simdutf8`              | `rust/simdutf8`              | `641d57f313df57354246d2b68d4778c092e076c3` | June 15, 2026      | [MIT OR Apache-2.0][simdutf8-readme]                                     | UTF encoding validity; no versioned category database                                |
| `encoding_rs`           | `rust/encoding_rs`           | `a155adc7271c9e507556d053c95b459186671d2a` | September 24, 2026 | [(Apache-2.0 OR MIT) AND BSD-3-Clause][encoding-manifest]                | WHATWG encodings; UTF transcoding does not require a width/category database         |
| `simd-normalizer`       | `rust/simd-normalizer`       | `d2352acda3e1709b07d649dcbdd542bd9c1d2540` | July 13, 2026      | [Apache-2.0][normalizer-manifest]                                        | 17                                                                                   |
| `unicode-segmentation`  | `rust/unicode-segmentation`  | `346f36a42592047c3f3f324141554f05ac0b5908` | September 17, 2026 | [MIT OR Apache-2.0][seg-manifest]                                        | [18][seg-tables]                                                                     |
| `unicode-normalization` | `rust/unicode-normalization` | `b77212b847ead642538c9c63060ac59f7a8563c5` | September 18, 2026 | [(MIT OR Apache-2.0) AND Unicode-3.0][norm-manifest]                     | [18][norm-tables]                                                                    |
| `unicode-width`         | `rust/unicode-width`         | `5180748ec0cacabfad0478996e9a89a612274e8f` | September 16, 2026 | [MIT OR Apache-2.0][width-manifest]                                      | [18][width-tables]                                                                   |
| `utf8proc`              | `c/utf8proc`                 | `4bfe012cb879a58a70715526e9db6a49486df571` | September 28, 2026 | [MIT plus Unicode data notice][utf8proc-license]                         | [18][utf8proc-readme]                                                                |
| `uni-algo`              | `cpp/uni-algo`               | `6c091fa266ac03a852128429af3b7481cf50a0ab` | January 5, 2024    | [Unlicense OR MIT][uni-license]; [Unicode data notice][uni-data-license] | [15.1][uni-readme]                                                                   |

> [!WARNING]
> A fresh clone is not a Unicode-version match. All three inspected `unicode-rs` heads and `utf8proc` already use Unicode 18; Sparkles' generated tables use 17. Restrict a comparison to a verified shared repertoire/properties or select an explicitly pinned Unicode-17 revision. A Cargo version constraint alone does not establish equivalent tables.

## How it works

### SIMD coverage and dispatch

| Implementation          | Actual vectorized work                                                                                                                                         | Scalar work / limitations                                                                                     | Exact implementation files                                                                                                                                                           |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `xutf`                  | Portable `core::simd` ASCII scans; mixed-width transcoding; focused AVX-512 and NEON kernels; ANSI introducer discovery; normalization ASCII quick-check       | Property lookup, cluster join state, decomposition, ordering, composition; permissive raw codecs              | [`src/simd.rs`][xutf-simd], [`src/native.rs`][xutf-native], [`src/x86.rs`][xutf-x86], [`src/neon.rs`][xutf-neon], [`src/strip.rs`][xutf-strip], [`src/normalize.rs`][xutf-normalize] |
| `simdutf8`              | Lookup/shuffle UTF-8 validity checks, ASCII fast path; x86 AVX-512/AVX2/SSE4.2, ARM NEON, Wasm SIMD                                                            | Short-input scalar fallback; exact error localization in `compat` uses scalar validation around the bad block | [`src/implementation/algorithm.rs`][simdutf8-algorithm], [`src/implementation/x86/mod.rs`][simdutf8-dispatch], [README technical details][simdutf8-readme]                           |
| `encoding_rs`           | `core::simd` acceleration behind `simd-accel`; UTF-8 validation delegates to `simdutf8` on supported architectures even without that feature                   | Scalar paths remain; legacy encodings are a separate contract                                                 | [`src/mem.rs`][encoding-mem], [`src/simd_funcs.rs`][encoding-simd], [feature/dispatch documentation][encoding-readme]                                                                |
| `simd-normalizer`       | 64-byte bound classification, masks identifying exceptional bytes; form-specific quick-check safe ranges; x86 SSE4.2/AVX2/AVX-512, ARM NEON/SVE2, Wasm SIMD128 | Scalar decode/decomposition/CCC buffering/composition and scalar property trie lookups                        | [`src/simd/mod.rs`][normalizer-dispatch], [`src/simd/x86_64/avx2.rs`][normalizer-avx2], [`src/normalizer.rs`][normalizer-main], [`src/quick_check.rs`][normalizer-qc]                |
| `unicode-segmentation`  | No explicit SIMD in inspected boundary algorithm                                                                                                               | `char` iteration and grapheme category/state-machine transitions                                              | [`src/grapheme.rs`][seg-grapheme]                                                                                                                                                    |
| `unicode-normalization` | No explicit SIMD in inspected normalization iterators                                                                                                          | Scalar decomposition/recomposition over `Iterator<Item = char>`                                               | [`src/decompose.rs`][norm-decompose], [`src/recompose.rs`][norm-recompose]                                                                                                           |
| `unicode-width`         | No explicit SIMD in inspected width algorithm                                                                                                                  | Reverse scalar `chars()` fold carrying width state                                                            | [`src/lib.rs`][width-lib], [`src/lookup.rs`][width-lookup]                                                                                                                           |
| `utf8proc`              | **Scalar baseline**, not a SIMD competitor                                                                                                                     | Strict scalar decoder; staged property lookup; stateful grapheme rules; normalization                         | [`utf8proc.c`][utf8proc-c]                                                                                                                                                           |
| `uni-algo`              | **Scalar/SWAR baseline**, not a SIMD competitor                                                                                                                | Scalar staged lookups and Unicode state; four-byte ASCII conversion optimization                              | [`impl_conv.h`][uni-conv], [`impl_norm.h`][uni-norm], [`impl_segment_grapheme.h`][uni-grapheme]                                                                                      |

`xutf` requires nightly features including `portable_simd`, as visible in [`src/lib.rs`][xutf-lib]. Some specialized codec instructions are compiled conditionally; `PEXT`/`PDEP` are scalar BMI2 instructions, **not SIMD**. Its specialized x86 availability check is in [`src/x86.rs`][xutf-x86]. A benchmark must report target features and selected path rather than equating the presence of an AVX-512 source file with execution of it.

`simdutf8` uses runtime x86 selection unless target features fix the implementation at compile time. Its documentation says inputs shorter than 64 bytes use `core::str::from_utf8()` except direct implementation APIs. `encoding_rs` separately distinguishes `simd-accel` plus `std` multiversioning from its UTF-8 validation dispatch; record both features when benchmarking. `simd-normalizer` caches the x86 backend through `OnceLock`; its ARM implementation instead uses a cached NEON/SVE2 decision and direct branches. These are source facts, not observed backend execution here.

### Unicode property lookup and state

The `xutf` property table is not a vector gather. [`props(cp)`][xutf-props] does one direct indexed byte load for the 65,536 BMP entries; astral scalars use a first-stage index and a 128-codepoint leaf. The packed byte contains grapheme-break class, two width bits, `Extended_Pictographic`, and Indic-conjunct extension state. Out-of-range raw values receive the documented `DEFAULT_PROPS` (width one, break class `Other`).

The separate category/script word packs both properties together. [`src/ucd.rs`][xutf-ucd] documents why its default is one release behind width/grapheme data; [`Cargo.toml`][xutf-manifest] enables Unicode 17 category/script data only with `ucd-17`. Do not copy the README's broad “Unicode 17” description into a category-lookup claim without this qualification.

[`ClusterState` and `next_cluster`][xutf-grapheme] combine segmentation and terminal width without materializing decoded clusters. [`measure_width`][xutf-width] retains the rejected boundary scalar and its property byte for the next cluster. Its `simple(p)` shortcut admits `Other`/`LV`/`LVT` only when extended pictographic and pending emoji-text promotion are excluded. This is a restricted state optimization, not “all non-ASCII codepoints are additive.”

### Normalization and analysis

`xutf` offers NFC/NFD/NFKC/NFKD transformations with scalar generated decomposition/composition data and a SIMD ASCII scan. Its [`make_nfc`/`make_nfkc`][xutf-normalize] interfaces reuse an owned string's allocation and report required capacity when expansion does not fit. Its `to_*` interfaces copy the input; `into_*` may grow capacity. Capacity policy is part of any fair comparison.

`xutf::is_nfc` and `is_nfkc` are **conservative quick-check predicates**: `false` can mean `Maybe`, not that output must change. The pinned source explicitly says “`false` means normalization _may_ change the text.” They must not be benchmarked as interchangeable exact normalizedness predicates.

`simd-normalizer` exposes [`nfc().normalize(&str)`][normalizer-api] and corresponding forms, returning `Cow<str>`. Already-normalized inputs may remain borrowed; changing inputs produce output storage. Its SIMD bound masks bypass safe regions; its scalar engine still orders combining classes and composes. Its [`casefold`][normalizer-fold] uses Unicode **simple** C+S folding and optional Turkish overrides; ASCII classification is vectorized but ASCII lowercasing in that path is scalar. The default matching/confusable pipeline is not Sparkles' analyzer.

The scalar Rust normalization baseline describes its actual output surface as “Methods for iterating over strings while applying Unicode normalizations” in [`src/lib.rs`][norm-lib]. Consuming an iterator to obtain normalized values and collecting it into a UTF-8 `String` are different measured jobs.

## Analysis

### Contracts and error offsets

| Surface                 | Sparkles contract in inspected sources                                                                                                                            | Competitor compatibility                                                                                                                                                                                                                   |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Strict UTF-8 validation | `indexOfInvalidUtf8` returns input length or the start byte of the first invalid sequence; overlongs, surrogates, truncation and out-of-range encodings fail      | `simdutf8::compat::from_utf8(...).err().valid_up_to()` supplies the compatible first-error surface. `basic` is only a boolean/full-scan comparison. `xutf` raw codecs do not validate.                                                     |
| Malformed analysis      | Each malformed byte becomes a distinct opaque unit above the scalar range, retaining byte provenance                                                              | Valid-`str` normalization interfaces cannot accept the same input. `utf8proc` returns a UTF-8 error; `uni-algo` lenient operations replace malformed sequences. None is a full analyzer substitute.                                        |
| Scalar width            | Controls, noncharacters, separators, all `Mn`/`Mc`/`Me`/`Cf`, and conjoining ranges zero; regional indicators two; ambiguous narrow                               | `unicode-width::UnicodeWidthChar::width` returns `None` for controls, requiring an explicit zero policy. `xutf` follows a different zero-width set, not “all `Mc` zero.” `utf8proc_charwidth` is scalar width, not cluster width.          |
| Cluster width           | Leading-codepoint width adjusted by Sparkles' VS15/VS16 policy; cluster members do not add width                                                                  | `xutf` has join-state/promotion rules and documents differences from `unicode-width`, including VS15 and bare keycaps. `unicode-width` includes script-specific ligatures and U+17D8 width three. Output agreement must gate each fixture. |
| ANSI width              | `visibleWidth` recognizes ESC-prefixed sequences using `escapeLength`; unterminated sequences consume remaining input                                             | `xutf::width` does **not** remove ANSI; `width_ansi` does. The latter also accepts C1 introducers, unlike Sparkles' ESC-only discovery. ESC-based SGR/OSC fixtures are candidates, not proof of parser identity.                           |
| Graphemes               | Phobos `graphemeStride`; decoded window capped at 32 codepoints; malformed decoding uses replacement; escapes are separate zero-width items                       | `xutf` supplies Unicode-17 extended graphemes without that cap; `unicode-segmentation`/`utf8proc` heads supply Unicode 18. Exclude malformed text, escapes and over-cap clusters for a common boundary-only comparison.                    |
| Analysis output         | Bounded `TextUnit` values plus byte spans/flags; NFC or NFKC, sensitive/simple/full fold, optional mark stripping/word flags/stopwords; explicit capacity failure | A normalizer-only row lacks provenance, flags, folding and capacity semantics. Label it a **component comparison**, never end-to-end `analyzeText` speed.                                                                                  |

Sources: [Sparkles validation][spk-utf8], [width][spk-width], [clusters][spk-grapheme], [ANSI grammar][spk-ansi], [analysis][spk-analysis]; [`xutf` width policy][xutf-width], [property generator][xutf-generator], [ANSI parser][xutf-strip]; [`unicode-width` policy][width-lib]; [`utf8proc` API/errors][utf8proc-h]; [`uni-algo` error policy][uni-readme].

Sparkles' generated width/normalization tables declare Unicode 17, but the inspected width and grapheme modules also use Phobos categories/segmentation. The generated version alone therefore does not establish that every property in the entire width/segmentation pipeline is Unicode 17. Record the D runtime version or compare outputs directly.

### Bounds, tails and dispatch

The [dispatch inventory](#simd-coverage-and-dispatch) establishes available implementations, not the backend a local binary executed. `xutf::plain_prefix` uses full in-bounds SIMD windows plus a scalar tail. Its other ASCII kernels can overlap a final window; that does not grant a caller permission to read beyond a slice. The normalizer's AVX2 scanner requires 64 readable bytes, with shorter input handled elsewhere. For any D adaptation, retain a bounded scalar tail, explicit target-feature selection, and the existing fallback; report actual build features with results.

Sparkles' 32-codepoint grapheme cap and analyzer segment/output capacities are independent bounds. An unlimited competitor cannot establish equivalence at those failure or split boundaries. Width-only optimizations must also preserve pending presentation context at the ASCII/non-ASCII transition.

### Benchmark fit and evidence

These are proposed rows for `sparkles:test-runner` integration, **not executed results**. Verify exact outputs before entering timings into a shared chart.

| Measured operation                      | Shortlisted API                                                                                                                                                                            | Candidate shared fixture / excluded cases                                                                                                                                                                                                                       |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Validity plus first invalid byte        | `simdutf8::compat::from_utf8`; Sparkles `indexOfInvalidUtf8`                                                                                                                               | Valid ASCII/mixed UTF-8 plus malformed leads/second bytes and block-crossing truncation. Normalize success to input length and error to `valid_up_to`. Include early/late errors separately.                                                                    |
| Boolean full-input validity             | `simdutf8::basic::from_utf8`                                                                                                                                                               | Separate chart from first-error semantics; never supply fabricated offsets.                                                                                                                                                                                     |
| UTF-8 → UTF-16 into preallocated output | `encoding_rs::mem::convert_utf8_to_utf16_without_replacement`; `xutf::transcode_into::<Utf8, Utf16>(src, dst, AsciiCase::Preserve)`                                                        | Well-formed inputs only; destination sized for the largest documented requirement; compare produced code units, not lengths alone. Replacement/first-error behavior is not common.                                                                              |
| UTF-16 → UTF-8 into preallocated output | `encoding_rs::mem::convert_utf16_to_utf8`; `xutf::transcode_into::<Utf16, Utf8>(src, dst, AsciiCase::Preserve)`                                                                            | Valid paired UTF-16 only. `encoding_rs` replaces unpaired surrogates; `xutf` raw codecs preserve permissive values.                                                                                                                                             |
| Plain terminal-cell width               | `xutf::width_str`; `unicode_width::UnicodeWidthStr::width`; Sparkles `visibleWidth`                                                                                                        | Printable ASCII, CJK prose, precomposed Latin, ordinary combining accents and common emoji/RI, **after output agreement**. No ANSI, control/ligature/presentation edge cases or pathological clusters in a supposedly common row.                               |
| ESC-styled width                        | `xutf::width_ansi_str`; Sparkles `visibleWidth`                                                                                                                                            | Valid ESC-based SGR and OSC 8 around compatible text; classify C1 and unterminated/malformed grammar cases separately. No allocating strip-then-width adapter silently treated as a direct API.                                                                 |
| Extended-grapheme boundaries            | `xutf::grapheme_indices::<Utf8>`; `UnicodeSegmentation::grapheme_indices(text, true)`; `utf8proc_grapheme_break_stateful` with strict decode                                               | Valid escape-free text, shared Unicode repertoire, clusters within Sparkles' 32-codepoint window. Hash/compare boundary offsets, not just cluster count. `xutf` also computes width; disclose that extra work.                                                  |
| NFC/NFKC transformed scalar values      | `simd_normalizer::nfc()/nfkc().normalize`; `xutf` normalization traits; `unicode_normalization::UnicodeNormalization::nfc()/nfkc()`; `utf8proc_map`; `una::norm::to_nfc_utf8/to_nfkc_utf8` | Valid common-repertoire inputs and forms, case-sensitive/no mark stripping. Separate iterator consumption, borrowed-result, in-place and allocated UTF-8-output rows. Sparkles comparison is the normalization **component**, not complete provenance analysis. |

Upstream benchmark entry points useful for adapter work are `xutf/benches/width.rs`, `benches/width_ansi.rs`, `benches/graphemes.rs`, `benches/normalize.rs`, and `benches/throughput.rs`; their published numbers are not substituted for a same-host runner.

### D/CTFE and license fit

The Rust vector intrinsics are not directly executable D CTFE code. A port should keep the established scalar compile-time path and specialize runtime byte scanning only. Preserve the existing Unicode tables, caps, ANSI grammar, and leading-codepoint width policy: the proposed ASCII-prefix optimization leaves the last ASCII starter before non-ASCII to the scalar cluster path rather than importing `xutf`'s width semantics.

The inventory records software and derived-data licenses separately where manifests/notices require it. MIT/Apache code is not unlicensed pseudocode; keep required notices if code is copied. Likewise, generating new tables from upstream Unicode data requires preserving its applicable data notice. Algorithm inspiration does not justify copying a competitor's Unicode generation or width overrides silently.

## Implementation ideas for Sparkles

Each item is a design inference from cited source, not a measured speedup or an instruction to change Unicode policy.

1. **Printable ASCII width in bulk.** Follow [`xutf::plain_prefix`][xutf-simd]: reject a non-plain head cheaply, vector-scan `0x20..=0x7E`, and return to the established scalar/cluster path at an exceptional byte. Preserve ANSI boundaries and the last possible presentation-sensitive base. `xutf` holds `#`, `*`, and digits before VS16/keycap continuation; Sparkles has its own [`graphemeClusterWidth`][spk-width] policy, so derive its boundary condition from that policy instead of copying the whitelist unexamined.
2. **Avoid repeated decoding/property work.** [`measure_width`][xutf-width] carries a lookahead scalar/property into the next cluster and admits provably simple runs. This suggests reducing `scanCluster`'s repeated prefix `graphemeStride` and width rescans, while retaining its cap, output fields and malformed behavior. Use a state-machine-compatible shortcut; do not treat all CJK, all marks or all non-ASCII as interchangeable.
3. **Fused generated scalar properties.** The [`xutf` packed table][xutf-props] can replace several separate tests with one scalar lookup. A direct BMP array trades about 64 KiB for one-load indexing; an all-plane deduplicated trie trades additional dependent loads for smaller tables. Generate from Sparkles' own source/version/policy and benchmark short terminal strings, mixed text, and cache pressure before selecting a layout. This is a property-layout idea, not evidence that gathers would help.
4. **Analysis ASCII specialization without losing materialization.** [`analyzeText`][spk-analysis] still must emit every unit, source span and uppercase flag even when normalization is a no-op. A vector ASCII/uppercase probe can bypass Unicode lookup/decomposition for known-safe runs, but must flush any pending combining segment and maintain word/fold/stopword policy and exact capacity errors. A borrowed `Cow` return is not a valid fast-path replacement for this API.
5. **Safe-region normalization checks.** [`simd-normalizer` quick-check][normalizer-qc] classifies byte ranges and known-safe scripts before scalar trie lookup. These bounds depend on form and valid UTF-8: NFC-safe is not NFKC-safe, and Sparkles accepts opaque malformed bytes. Reuse only an explicitly proven byte/scalar subset; never skip provenance, folding, or pending composition across its boundary.
6. **Do not pay normalization allocation to benchmark analysis.** [`xutf` in-place capacity handling][xutf-normalize] and [`simd-normalizer` borrowed/owned results][normalizer-api] illustrate separate storage models. Make storage policy and produced output part of the row name rather than crediting different work as algorithm speed.

## Strengths

- Real SIMD implementations are inspectable in local, pinned source trees; no reliance on crate descriptions alone.
- `xutf` combines width and segmentation with compact scalar properties and allocation-free borrowed outputs, closely matching terminal workloads.
- `simdutf8::compat` offers a strict first-error surface; `encoding_rs` offers slice-output transcoding APIs.
- `simd-normalizer` is an actual SIMD-guided normalization competitor with explicit scalar boundaries and dispatch.
- Scalar baselines expose independent property layouts and Unicode algorithms, making them useful correctness/component references.

## Weaknesses

- There is no drop-in full competitor for Sparkles' bounded, malformed-byte-preserving, provenance-bearing analyzer in this shortlist.
- Unicode versions and width policies differ substantially; matching an operation name is insufficient.
- Nightly features, backend dispatch, allocation, cluster caps and ANSI grammar can dominate or invalidate an ostensibly common comparison.
- No local runtime result is established here; source structure alone cannot rank implementations on a host.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                                             | Trade-off                                                                          |
| -------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Separate SIMD scans from scalar Unicode algorithms | Vector intrinsics prove actual acceleration coverage, not acceleration of every stage | More precise reporting; fewer broad “SIMD Unicode” claims                          |
| Keep first-error and boolean validation distinct   | Exact failure location/early exit is consumer-visible work                            | Two benchmark contracts instead of a misleading single ranking                     |
| Retain scalar competitors                          | Independent algorithms and data layouts inform correctness and implementation         | They cannot be presented as SIMD implementations                                   |
| Gate fixtures on output agreement                  | Unicode versions, terminal policies and grapheme caps differ                          | A compatible subset supports a scoped result, not universal equivalence            |
| Compare normalization as a component               | Search analysis additionally emits provenance, flags and bounded errors               | No claim that standalone normalization replaces or outruns complete analysis       |
| Pin local heads without modifying existing clones  | Reproducible source and respect for user checkouts                                    | Unicode-18 heads need deliberate matching inputs or a separately selected revision |

## Sources

- [`xutf` manifest][xutf-manifest], [codec/library contract][xutf-lib], [packed properties][xutf-props], [property generator][xutf-generator], [width scanner][xutf-width], [grapheme state][xutf-grapheme], [normalization][xutf-normalize], and [ANSI scanner][xutf-strip].
- [`simdutf8` contracts and dispatch notes][simdutf8-readme], [validation algorithm][simdutf8-algorithm], and [x86 dispatch][simdutf8-dispatch]. The README cites Keiser and Lemire's [_Validating UTF-8 In Less Than One Instruction Per Byte_][utf8-paper]; this page's implementation findings come from the pinned Rust source, not a locally rerun paper benchmark.
- [`encoding_rs` implementation/feature notes][encoding-readme], [license/features][encoding-manifest], [slice-output codecs][encoding-mem], and [SIMD helpers][encoding-simd].
- [`simd-normalizer` overview][normalizer-readme], [license][normalizer-manifest], [normalization core][normalizer-main], [quick-check][normalizer-qc], [AVX2 classifier][normalizer-avx2], [dispatch][normalizer-dispatch], and [simple folding][normalizer-fold].
- [`unicode-segmentation` scalar boundaries][seg-grapheme]; [`unicode-normalization` scalar decomposition][norm-decompose] and [recomposition][norm-recompose]; [`unicode-width` documented rules][width-lib] and [reverse-fold scanner][width-lookup].
- [`utf8proc` API][utf8proc-h], [scalar implementation][utf8proc-c], and [licenses][utf8proc-license]; [`uni-algo` rationale][uni-readme], [conversion][uni-conv], [normalization][uni-norm], and [grapheme state][uni-grapheme].

<!-- References -->

[xutf-readme]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/README.md
[xutf-manifest]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/Cargo.toml
[xutf-lib]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/lib.rs
[xutf-simd]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/simd.rs
[xutf-native]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/native.rs
[xutf-x86]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/x86.rs
[xutf-neon]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/neon.rs
[xutf-props]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/props.rs
[xutf-ucd]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/ucd.rs
[xutf-generator]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/scripts/gen_props.py
[xutf-width]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/width.rs
[xutf-grapheme]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/grapheme.rs
[xutf-strip]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/strip.rs
[xutf-normalize]: https://github.com/can1357/xutf/blob/9bb347af041369a68a4effd1ca85c6d2f9b4e17b/src/normalize.rs
[simdutf8-readme]: https://github.com/rusticstuff/simdutf8/blob/641d57f313df57354246d2b68d4778c092e076c3/README.md
[simdutf8-algorithm]: https://github.com/rusticstuff/simdutf8/blob/641d57f313df57354246d2b68d4778c092e076c3/src/implementation/algorithm.rs
[simdutf8-dispatch]: https://github.com/rusticstuff/simdutf8/blob/641d57f313df57354246d2b68d4778c092e076c3/src/implementation/x86/mod.rs
[encoding-readme]: https://github.com/hsivonen/encoding_rs/blob/a155adc7271c9e507556d053c95b459186671d2a/README.md
[encoding-manifest]: https://github.com/hsivonen/encoding_rs/blob/a155adc7271c9e507556d053c95b459186671d2a/Cargo.toml
[encoding-mem]: https://github.com/hsivonen/encoding_rs/blob/a155adc7271c9e507556d053c95b459186671d2a/src/mem.rs
[encoding-simd]: https://github.com/hsivonen/encoding_rs/blob/a155adc7271c9e507556d053c95b459186671d2a/src/simd_funcs.rs
[normalizer-readme]: https://github.com/DevExzh/simd-normalizer/blob/d2352acda3e1709b07d649dcbdd542bd9c1d2540/README.md
[normalizer-manifest]: https://github.com/DevExzh/simd-normalizer/blob/d2352acda3e1709b07d649dcbdd542bd9c1d2540/Cargo.toml
[normalizer-api]: https://github.com/DevExzh/simd-normalizer/blob/d2352acda3e1709b07d649dcbdd542bd9c1d2540/src/lib.rs
[normalizer-dispatch]: https://github.com/DevExzh/simd-normalizer/blob/d2352acda3e1709b07d649dcbdd542bd9c1d2540/src/simd/mod.rs
[normalizer-avx2]: https://github.com/DevExzh/simd-normalizer/blob/d2352acda3e1709b07d649dcbdd542bd9c1d2540/src/simd/x86_64/avx2.rs
[normalizer-main]: https://github.com/DevExzh/simd-normalizer/blob/d2352acda3e1709b07d649dcbdd542bd9c1d2540/src/normalizer.rs
[normalizer-qc]: https://github.com/DevExzh/simd-normalizer/blob/d2352acda3e1709b07d649dcbdd542bd9c1d2540/src/quick_check.rs
[normalizer-fold]: https://github.com/DevExzh/simd-normalizer/blob/d2352acda3e1709b07d649dcbdd542bd9c1d2540/src/casefold.rs
[seg-lib]: https://github.com/unicode-rs/unicode-segmentation/blob/346f36a42592047c3f3f324141554f05ac0b5908/src/lib.rs
[seg-manifest]: https://github.com/unicode-rs/unicode-segmentation/blob/346f36a42592047c3f3f324141554f05ac0b5908/Cargo.toml
[seg-tables]: https://github.com/unicode-rs/unicode-segmentation/blob/346f36a42592047c3f3f324141554f05ac0b5908/src/tables.rs
[seg-grapheme]: https://github.com/unicode-rs/unicode-segmentation/blob/346f36a42592047c3f3f324141554f05ac0b5908/src/grapheme.rs
[norm-lib]: https://github.com/unicode-rs/unicode-normalization/blob/b77212b847ead642538c9c63060ac59f7a8563c5/src/lib.rs
[norm-manifest]: https://github.com/unicode-rs/unicode-normalization/blob/b77212b847ead642538c9c63060ac59f7a8563c5/Cargo.toml
[norm-tables]: https://github.com/unicode-rs/unicode-normalization/blob/b77212b847ead642538c9c63060ac59f7a8563c5/src/tables.rs
[norm-decompose]: https://github.com/unicode-rs/unicode-normalization/blob/b77212b847ead642538c9c63060ac59f7a8563c5/src/decompose.rs
[norm-recompose]: https://github.com/unicode-rs/unicode-normalization/blob/b77212b847ead642538c9c63060ac59f7a8563c5/src/recompose.rs
[width-lib]: https://github.com/unicode-rs/unicode-width/blob/5180748ec0cacabfad0478996e9a89a612274e8f/src/lib.rs
[width-manifest]: https://github.com/unicode-rs/unicode-width/blob/5180748ec0cacabfad0478996e9a89a612274e8f/Cargo.toml
[width-tables]: https://github.com/unicode-rs/unicode-width/blob/5180748ec0cacabfad0478996e9a89a612274e8f/src/gen/tables.rs
[width-lookup]: https://github.com/unicode-rs/unicode-width/blob/5180748ec0cacabfad0478996e9a89a612274e8f/src/lookup.rs
[utf8proc-readme]: https://github.com/JuliaStrings/utf8proc/blob/4bfe012cb879a58a70715526e9db6a49486df571/README.md
[utf8proc-license]: https://github.com/JuliaStrings/utf8proc/blob/4bfe012cb879a58a70715526e9db6a49486df571/LICENSE.md
[utf8proc-c]: https://github.com/JuliaStrings/utf8proc/blob/4bfe012cb879a58a70715526e9db6a49486df571/utf8proc.c
[utf8proc-h]: https://github.com/JuliaStrings/utf8proc/blob/4bfe012cb879a58a70715526e9db6a49486df571/utf8proc.h
[uni-readme]: https://github.com/uni-algo/uni-algo/blob/6c091fa266ac03a852128429af3b7481cf50a0ab/README.md
[uni-license]: https://github.com/uni-algo/uni-algo/blob/6c091fa266ac03a852128429af3b7481cf50a0ab/LICENSE.md
[uni-conv]: https://github.com/uni-algo/uni-algo/blob/6c091fa266ac03a852128429af3b7481cf50a0ab/include/uni_algo/impl/impl_conv.h
[uni-norm]: https://github.com/uni-algo/uni-algo/blob/6c091fa266ac03a852128429af3b7481cf50a0ab/include/uni_algo/impl/impl_norm.h
[uni-grapheme]: https://github.com/uni-algo/uni-algo/blob/6c091fa266ac03a852128429af3b7481cf50a0ab/include/uni_algo/impl/impl_segment_grapheme.h
[spk-utf8]: ../../../libs/base/src/sparkles/base/text/utf8.d
[spk-width]: ../../../libs/base/src/sparkles/base/text/width.d
[spk-grapheme]: ../../../libs/base/src/sparkles/base/text/grapheme.d
[spk-ansi]: ../../../libs/base/src/sparkles/base/text/ansi.d
[spk-analysis]: ../../../libs/base/src/sparkles/base/text/analysis.d
[utf8-paper]: https://arxiv.org/abs/2010.03090
[uni-data-license]: https://github.com/uni-algo/uni-algo/blob/6c091fa266ac03a852128429af3b7481cf50a0ab/include/uni_algo/impl/data/LICENSE.txt
