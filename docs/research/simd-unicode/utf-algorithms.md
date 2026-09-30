# SIMD UTF algorithms (C/C++ and academic research)

Byte-stream validation, shuffle-table transcoding, and bit-stream alternatives inform a bounded, allocation-free D implementation without changing its error-offset contract.

**Last reviewed:** September 30, 2026.

| Property             | Evidence                                                                                                       |
| -------------------- | -------------------------------------------------------------------------------------------------------------- |
| Language             | C/C++; algorithms transferable to D, intrinsics not executable during D CTFE                                   |
| Category             | UTF validation, transcoding, algorithm history                                                                 |
| Main repository      | [`simdutf/simdutf`][simdutf]                                                                                   |
| License              | `simdutf`: Apache-2.0 or MIT; `is_utf8`: Apache-2.0, Boost-1.0 or MIT; `utf8_range`: MIT; `utf8lut`: Boost-1.0 |
| Contract of interest | Bounded input, first invalid sequence offset, caller-owned output, no allocation                               |
| Evidence level       | Primary papers and inspected, commit-pinned local source; this page does not report local throughput           |

> [!IMPORTANT]
> A paper's throughput is evidence about its stated hardware, corpus, compiler, and API, not proof of a universal fastest implementation. Boolean validation, first-error validation, non-validating conversion, and bounded partial conversion are different workloads. The local benchmark report must name which one it measured.

## Overview

### What it solves

A scalar UTF-8 decoder branches on character width and continuation bytes. A SIMD validator instead checks many positions simultaneously, including malformed continuations, overlong encodings, surrogates, and values above `U+10FFFF`. Transcoding adds a second problem: variable-length inputs must be gathered into fixed-width code units, or fixed-width units compacted into variable-length output.

[Keiser and Lemire][lookup-paper] give a byte-stream lookup algorithm; [Lemire and Muła][transcode-paper] use small shuffle tables for UTF-8/UTF-16 conversion; [Clausecker and Lemire][avx512-paper] replace those conversion tables with AVX-512 compression operations. [Cameron's Parabix predecessor][parabix-paper] transposes bytes into parallel bit streams before validating and transcoding.

### Design philosophy

The inspected `simdutf` validator separates bulk rejection from precise diagnostics. Its source describes the scalar repair step:

> “Finds the previous leading byte starting backward from buf and validates with errors from there” — [`include/simdutf/scalar/utf8.h`][scalar-utf8], lines 225–230.

The equally important design constraint is not to treat every ancestor as a current benchmark competitor:

> “The fastvalidate-utf-8 repository is for demonstration purposes.” — [`fastvalidate-utf-8/README.md`][fastvalidate-readme], line 10. The preceding notice calls it obsolete as of 2022.

## How it works

### Keiser–Lemire: three nibble lookups and continuation consistency

In [`utf8_lookup4_algorithm.h`][lookup-source], `check_special_cases(input, prev1)` indexes three register-resident 16-entry tables using the previous byte's high nibble, its low nibble, and the current byte's high nibble. A bitwise AND intersects their classifications. Bits represent error families; bit 7 records a pair of continuation bytes, which is not by itself an error.

```cpp
return (byte_1_high & byte_1_low & byte_2_high);
```

The source's `check_multibyte_lengths` then shifts in the preceding two and three byte positions. It computes where a pair of continuations is required and XORs that requirement with the classification result. Missing and excess third/fourth continuations become nonzero error lanes. `utf8_checker` ORs errors into a sticky vector and preserves the preceding input vector across chunks.

The all-ASCII path is only correct if the previous block did not end inside a multibyte sequence. `prev_incomplete` checks the last three positions against `F0`, `E0`, and `C0` thresholds; both the ASCII shortcut and `check_eof()` incorporate it. This is essential even for an input length exactly divisible by the vector/block width.

The paper's “less than one instruction per byte” is a measured retired-instruction result, not an instruction count for every compiler or ISA. Its benchmark discussion explicitly warns that repeated small inputs allow branch predictors to learn character-width patterns. Include varied inputs as well as cache-hot repeats when interpreting small-buffer results.

### Google range validation: propagate length classes, then bound each byte

The inspected [`utf8_validity.cc`][range-source] assigns a range index to every byte: ASCII, lead, continuation position, or a special second-byte constraint after `E0`, `ED`, `F0`, or `F4`. Shifts and saturating subtraction propagate expected continuation positions; table shuffles obtain minimum and maximum legal values. Overlapping lead/continuation expectations produce indices for impossible ranges.

This differs mechanically from the lookup algorithm: it performs per-byte range comparisons rather than intersecting three error-pattern tables. `ValidUTF8<false>` accumulates errors; `ValidUTF8<true>` branches on a failing SIMD block, backs up to the preceding code point, and invokes `ValidUTF8Span` to recover the longest valid prefix. The same file skips ASCII eight bytes at a time before entering its 16-byte SSE path.

### Lemire–Muła: compact shuffle tables, full scalar-value coverage

[`avx2_convert_utf8_to_utf16.cpp`][avx2-transcode] uses a code-point-end mask to select how many bytes to consume and a shuffle layout. Its generic paths process six one/two-byte characters, four BMP characters, or two arbitrary characters, including supplementary code points. Fast paths recognize repeated ASCII, two-byte, and three-byte patterns. Shuffling aligns payload bits; shifts and masks remove the UTF-8 tags and construct UTF-16 units or surrogate pairs.

The paper describes a 12-byte indexing scheme and a 1024-entry main table. **Do not copy that count into a description of today's source:** the inspected [`utf8_to_utf16_tables.h`][transcode-tables] has `utf8bigindex[4096][2]` and `shufutf8[209][16]`: 8192 + 3344 = 11,536 bytes before alignment. The source comment explicitly describes the trade-off between storing consumed length and deriving it.

For the reverse direction, the paper separates all-ASCII, one/two-byte, general BMP, and surrogate-containing input. Its conventional SIMD design can fall back to scalar for surrogate handling. That describes the paper's implementation family, not an assurance that every modern backend uses the same fallback.

### Clausecker–Lemire: AVX-512 is a different compaction algorithm

The AVX-512 paper uses masks and compression operations unavailable in AVX2, not merely twice-wide registers. [`icelake_convert_utf16_to_utf8.inl.cpp`][avx512-source] materializes tagged candidate bytes, builds masks of bytes to keep, calls `_mm512_maskz_compress_epi8`, and stores only the compacted byte count with masked stores. It uses `popcount` for output advancement and BMI2 `_pext_u64` to form contiguous store masks.

The loop loads 32 UTF-16 words but normally advances by 31, retaining overlap for boundary-sensitive processing. Its tail uses `_mm512_maskz_loadu_epi16` and a mask reflecting the remaining valid input lanes. [`icelake_from_utf8.inl.cpp`][avx512-input] likewise masks partial UTF-8 validation loads. An AVX-512 implementation needs the particular required extensions, especially byte compression from `AVX512VBMI2`; the presence of `AVX512F` alone is insufficient.

### Parabix: transpose, bitwise semantics, delete, transpose back

Cameron's 2008 algorithm converts 128 input bytes into eight 128-bit basis streams, one per bit position. Boolean combinations classify lead and continuation bytes; whole-bitblock shifts mark required continuation positions; XOR detects disagreement with the actual continuation stream. UTF-16 payload bits are calculated at selected UTF-8 positions, unwanted positions deleted, then sixteen output basis streams transposed back into UTF-16 bytes.

The paper's block strategy shortens a block by up to three bytes to avoid splitting a code point. It reports substantial transform/inverse-transform cost on Core 2, despite inexpensive semantic bitwise logic. This makes it an instructive alternative when several text operations share basis streams, not an obvious cutover for a standalone D validator. The inspected `simdutf` research copy's [`u8u16/COPYRIGHT`][u8u16-license] states OSL-3.0 and “Patents pending”; the paper describes a patentleft commercialization model. Neither establishes present patent status or blanket compatibility with Boost-licensed code.

### Gatilov's `utf8lut`: large tables and BMP fast paths

The discovered repository is [`stgatilov/utf8lut`][utf8lut], migrated from Bitbucket according to its own readme. [`DecoderProcess.h`][lut-decoder] turns a 16-byte continuation mask into a table index, shuffles lower payload bytes, uses `_mm_maddubs_epi16` to combine them, and adds third-byte payload bits for BMP characters. The validating variant checks header patterns, minimum decoded values, and surrogates.

[`DecoderLut.h`][lut-table] declares 32,768 entries, removing impossible odd indices. A validating entry includes two conversion vectors and two validation vectors, giving a nominal 2 MiB layout on the intended 16-byte-vector target. [`BufferDecoder.h`][lut-buffer] provides one or four interleaved streams and calls scalar `DecodeTrivial` for rejected SIMD blocks, supplementary characters, and the final tail. Its minimum output sizing includes four extra units per stream. This is useful history about latency hiding and table/cache trade-offs; its padded-output and processor-object contract is not the Sparkles bounded writer contract.

The table is not a compile-time constant in this implementation: [`DecoderLut.cpp`][lut-initialization], lines 128–134, allocates it with `_mm_malloc` and computes its contents on first use. Any benchmark must separate initialization from steady-state conversion; adopting this initialization would also conflict with an allocation-free D entry point.

## Contracts and error offsets

| API                                         | Success result                                | Failure result                    | Fair comparison                                            |
| ------------------------------------------- | --------------------------------------------- | --------------------------------- | ---------------------------------------------------------- |
| `simdutf::validate_utf8`                    | `bool`                                        | `false`, no location              | Boolean throughput only                                    |
| `simdutf::validate_utf8_with_errors`        | `SUCCESS`, `count = input length`             | Error code and input-byte offset  | First-invalid-sequence validation                          |
| `is_utf8`                                   | `bool`                                        | `false`, no location              | Boolean throughput only                                    |
| `utf8_range::IsStructurallyValid`           | `bool`                                        | `false`, no location              | Boolean throughput only                                    |
| `utf8_range::SpanStructurallyValid`         | Longest valid prefix length                   | Same prefix length, no error enum | Prefix/sequence-start validation                           |
| C `utf8_range2`                             | Integer `0`                                   | Integer `-1`, no location         | Boolean-status throughput after normalizing the C result   |
| `simdutf` validating conversion with errors | Output units written                          | Error position in input units     | Validating conversion with sufficient destination capacity |
| `utf8lut`, validating mode                  | Conversion status plus consumed/written state | Stops on invalid input            | Conversion only after adapting buffer/slow-path semantics  |

[`simdutf::result`][error-result] intentionally changes the meaning of `count` between validation/conversion success and error. In [`scalar/utf8.h`][scalar-utf8], malformed/missing continuations return the **sequence lead** position; overlong, surrogate, and out-of-range encodings also return the lead position. A stray continuation returns its own position. For example, the source returns zero for `E2 28 A1`: it does not return the failing continuation's position one. These are source-derived examples, not local runtime results.

[`generic_validate_utf8_with_errors`][validator-source] checks errors after each 64-byte block, backs up one byte when needed, and scalar-refines from the preceding lead. The boolean variant checks only at the end. Consequently, early-error timings, valid-throughput timings, and boolean timings need separate labels. Returning the first SIMD error lane directly is not necessarily compatible with a sequence-start offset.

## Bounds, tails and dispatch

- **Input bounds:** [`buf_block_reader<64>`][block-reader] retains a final block, fills a stack buffer with ASCII spaces, and copies only the remaining input. Even a 64-byte input uses the remainder route. Padding is scratch storage, not permission to read past a user's slice.
- **Output bounds:** generic SIMD transcoding can write beyond its logical advance while remaining within its required overall capacity. [`avx2_convert_utf8_to_utf16.cpp`][avx2-transcode] explicitly comments on four- and eight-byte overstores. The [`generic validating driver`][transcode-driver] reserves a margin derived from trailing lead bytes even for invalid input. Do not transplant only the inner kernel into a partial-capacity D writer.
- **Dispatch:** [`simdutf`'s implementation list][dispatch-source] is in priority order; first use installs an active implementation. [`isadetection.h`][isa-source] checks `OSXSAVE` and `XGETBV` state before admitting AVX2/AVX-512 and then checks individual extension bits. Record the selected backend, not just the CPU name, in benchmarks. Explicit overrides must be supported by the host.
- **Different dispatch guarantees:** the inspected [`is_utf8.cpp`][single-source], lines 591–642, detects x86 feature bits without the corresponding `OSXSAVE`/`XGETBV` gates found in this `simdutf` revision. Do not infer identical dispatch behavior just because the projects share algorithms.
- **Google build flags:** the inspected [`utf8_range.h`][range-api] selects NEON/SSE through compile-time macros; otherwise `utf8_range2` calls scalar `utf8_naive`. Its C API takes `int len`; adapters must avoid narrowing a D `size_t` silently. [`range2-sse.c`][range-c-source] returns **zero on success**, unlike the C++ boolean wrapper. The C++ prefix wrapper requires Abseil and enables SIMD only under `__SSE4_1__`, per [`CMakeLists.txt`][range-build] and source.

## Benchmark fit and evidence

### Shortlist versus algorithm history

| Subject              | Role                                                                                                | Reason                                                                                                  |
| -------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `simdutf`            | Primary benchmark: boolean, exact error, and bidirectional UTF-8/UTF-16 conversion as separate rows | Broad ISA support; non-allocating core; matching first-sequence-offset validator                        |
| `is_utf8`            | Optional boolean-only benchmark                                                                     | Small C ABI; same major lookup algorithm family, not an independent offset API                          |
| `utf8_range`         | Independent range-family benchmark                                                                  | C status core or C++ prefix wrapper; publish flags and dependency/adapter choice                        |
| `fastvalidate-utf-8` | Algorithm history, not primary production benchmark                                                 | Upstream declares it obsolete/demo; continuation-length carry rather than today's lookup implementation |
| `utf8lut`            | Optional historical transcoding comparison                                                          | Large LUTs, BMP-only SIMD, scalar supplementary handling, different buffer requirements                 |
| Parabix `u8u16`      | Algorithm history and license caution                                                               | Transposition pipeline, old backend assumptions, separately licensed research source                    |

Useful cases span empty and tiny strings; 15/16/17, 31/32/33 and 63/64/65-byte boundaries; long ASCII; two-byte, CJK, emoji and irregular mixed text; malformed input at the start, across a block boundary, and at the end; and each exceptional `E0`/`ED`/`F0`/`F4` second-byte range. Conversion comparisons must distinguish ample output space from every partial destination boundary and show whether a preceding complete sequence may have been written before failure.

Measure both the library function and the actual caller path. A faster validator does not establish a faster end-to-end JSON reader/writer if decoding, capacity checks, allocation, or unrelated parsing dominates. This survey does not promote paper results or clone availability into local runtime evidence.

### Local clone and PDF inventory

All checkouts below were newly cloned for this survey; revisions are source-inspection pins, not production dependency declarations.

| Repository                   | Local checkout                                | Inspected `HEAD`                           |
| ---------------------------- | --------------------------------------------- | ------------------------------------------ |
| `simdutf/simdutf`            | `/home/petar/code/repos/cpp/simdutf`          | `cf8715fad4d55c87aad3006a9a82531f740605b8` |
| `simdutf/is_utf8`            | `/home/petar/code/repos/cpp/is_utf8`          | `11f61076f87fcec3ba7880ac9b7f1bffca0c45f9` |
| `protocolbuffers/utf8_range` | `/home/petar/code/repos/c/utf8_range`         | `1d1ea7e3fedf482d4a12b473c1ed25fe0f371a45` |
| `lemire/fastvalidate-utf-8`  | `/home/petar/code/repos/c/fastvalidate-utf-8` | `c0a5f7ee26addce8c76a5c98b1120710db4060cb` |
| `stgatilov/utf8lut`          | `/home/petar/code/repos/cpp/utf8lut`          | `782b76000a0296aeb7252d2bc0d979c94cab3d74` |

The requested `google/utf8_range` URL returned HTTP 404; discovery located the archived `protocolbuffers/utf8_range` repository instead. No clone was silently substituted under a guessed owner.

Primary PDFs were downloaded outside the Sparkles tree to `/home/petar/code/repos/papers/simd-unicode/` and identified locally as PDF documents:

| Work                                      | Local filename                               | Version/source                                 |
| ----------------------------------------- | -------------------------------------------- | ---------------------------------------------- |
| Keiser–Lemire validation, published 2021  | `keiser-lemire-utf8-lookup-2010.03090v5.pdf` | [arXiv v5, April 21, 2026][lookup-paper]       |
| Lemire–Muła transcoding, published 2022   | `lemire-mula-transcoding-2109.10433v3.pdf`   | [arXiv v3, November 14, 2022][transcode-paper] |
| Clausecker–Lemire AVX-512, published 2023 | `clausecker-lemire-avx512-2212.05098v4.pdf`  | [arXiv v4, August 5, 2023][avx512-paper]       |
| Cameron parallel bit streams, PPoPP 2008  | `cameron-ppopp2008-parallel-bitstreams.pdf`  | [Author's manuscript][parabix-paper]           |

The first three journal publication years are grounded in [`simdutf`'s bibliography][simdutf-readme]. The 2008 author's manuscript explicitly prohibits redistribution; keep that download local rather than adding it to repository documentation assets.

## D/CTFE and license fit

**Recommendations, not measured claims:**

1. Keep the public first-invalid-sequence-offset contract. Use a runtime bulk checker to prove complete blocks valid, then existing scalar decoding to localize failures. A boolean-only external function is not a drop-in replacement.
2. Keep a scalar CTFE path selected with `__ctfe`; preserve the same handling of truncation, overlong sequences, surrogates, and values above `U+10FFFF`. Runtime SIMD and compile-time results must agree, while intrinsics stay outside CTFE evaluation.
3. Prefer a bounded ASCII block shortcut before deeper SIMD work for the existing scalar decoder/encoder. It can accelerate common caller loops without changing non-ASCII semantics or needing a conversion LUT. Choose its threshold and width from small-buffer and wired-path measurements, not a paper's bulk-byte results.
4. For runtime UTF-8 validation beyond ASCII, the nibble lookup design is a grounded candidate. Preserve cross-block continuation state and EOF validation; scalar-refine errors rather than treating every nonzero lane as the API offset. For tiny input, scalar avoids block setup, scratch-tail copy, and dispatch costs.
5. For partial transcoding, require a destination-size check before every bulk store. Fall back at the next complete sequence when capacity is tight. The `simdutf` sufficient-capacity conversion contract and `utf8lut` padded-output contract cannot be substituted for bounded slice semantics.
6. Do not add a 2 MiB generated LUT or Parabix basis-stream pipeline solely to improve a narrow helper without measured evidence. AVX-512 byte compression can eliminate conversion tables, but only on appropriately gated targets; keep portable fallback coverage.

Sparkles' root `LICENSE` is **Boost Software License 1.0**, not Business Source License. `utf8lut` uses the same license. `is_utf8` and historical `fastvalidate-utf-8` offer Boost alongside MIT/Apache choices; `simdutf` itself offers MIT/Apache, not Boost. MIT-derived source must retain its notices; a D translation is not an excuse to erase attribution. The [`simdutf` license section][simdutf-readme] specifically separates its competitive benchmark sources from the main library. Check each copied file, table, and embedded dependency rather than assigning the parent's license to all descendants. Parabix's OSL/patent history is a separate review concern; this survey makes no patent-expiry or legal-compatibility finding.

## Strengths

- Lookup validation has a concrete, small-table mechanism and an existing SIMD-plus-scalar exact-offset design to study.
- Range validation supplies a genuinely different implementation family for comparison.
- Modern `simdutf` covers supplementary code points and several ISA backends without allocation in its core conversion APIs.
- Papers explain table/cache, transform, branch-prediction, and compression-instruction trade-offs; source pins prevent historical descriptions from being mistaken for current implementation facts.

## Weaknesses

- No SIMD boolean API establishes bounded conversion or first-error semantics by itself.
- Bulk throughputs can hide tiny-buffer setup, tail repair, dispatch, partial capacity, or caller costs.
- ISA dispatch and padding assumptions differ even among related libraries.
- Historical competitors have large tables, supplementary fallbacks, old architecture assumptions, or separate licensing constraints.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                      | Trade-off                                                           |
| ----------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------- |
| SIMD valid-prefix proof, scalar diagnostic refinement | Keeps exact sequence-start semantics with cheap bulk rejection | Extra reduction/branch on valid blocks; scalar work on invalid ones |
| Bounded scalar tails or masked/scratch loads          | User slices need not have readable padding                     | Tail overhead relative to unsafe padded-input kernels               |
| Capacity-aware bulk stores                            | Partial output remains observable and correct                  | Cannot reuse ample-output overstore kernels unmodified              |
| Scalar CTFE plus gated runtime acceleration           | D compile-time execution cannot run ISA intrinsics             | Two execution paths require semantic parity                         |
| Measure selected backend and wired callers            | Avoids comparing algorithm names rather than executed code     | More precise labels and multiple workload shapes                    |

## Sources

- [Keiser and Lemire: UTF-8 lookup validation][lookup-paper], especially §§6–7.
- [Lemire and Muła: SIMD transcoding][transcode-paper], especially §§2, 4–6.
- [Clausecker and Lemire: AVX-512 transcoding][avx512-paper], especially §§3, 4.3, 6–8.
- [Cameron: parallel-bit-stream transcoding][parabix-paper], especially §§2, 4–7 and 9.
- Pinned source: [`simdutf` validator][validator-source], [lookup checker][lookup-source], [scalar offset refinement][scalar-utf8], [bounded block reader][block-reader], [AVX2 converter][avx2-transcode], [tables][transcode-tables], [driver safety margins][transcode-driver], [AVX-512 output][avx512-source], [AVX-512 input tails][avx512-input], [dispatch][dispatch-source], [ISA state detection][isa-source], and [result contract][error-result].
- Pinned competitors: [`is_utf8` implementation][single-source], [`utf8_range` implementation][range-source], [C API][range-api], [build/dependencies][range-build], [`fastvalidate-utf-8` status][fastvalidate-readme], and [`utf8lut` decoder][lut-decoder], [tables][lut-table], [buffer/tail processing][lut-buffer].

<!-- References -->

[simdutf]: https://github.com/simdutf/simdutf
[utf8lut]: https://github.com/stgatilov/utf8lut/tree/782b76000a0296aeb7252d2bc0d979c94cab3d74
[lookup-paper]: https://arxiv.org/abs/2010.03090v5
[transcode-paper]: https://arxiv.org/abs/2109.10433v3
[avx512-paper]: https://arxiv.org/html/2212.05098v4
[parabix-paper]: https://www2.cs.sfu.ca/~cameron/ppopp074-cameron.pdf
[simdutf-readme]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/README.md#license
[lookup-source]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/generic/utf8_validation/utf8_lookup4_algorithm.h
[scalar-utf8]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/include/simdutf/scalar/utf8.h#L117-L252
[validator-source]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/generic/utf8_validation/utf8_validator.h#L9-L79
[error-result]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/include/simdutf/error.h#L76-L96
[block-reader]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/generic/buf_block_reader.h
[avx2-transcode]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/haswell/avx2_convert_utf8_to_utf16.cpp
[transcode-tables]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/tables/utf8_to_utf16_tables.h
[transcode-driver]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/generic/utf8_to_utf16/utf8_to_utf16.h#L128-L147
[avx512-source]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/icelake/icelake_convert_utf16_to_utf8.inl.cpp
[avx512-input]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/icelake/icelake_from_utf8.inl.cpp
[dispatch-source]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/src/implementation.cpp#L1520-L1555
[isa-source]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/include/simdutf/internal/isadetection.h#L301-L368
[u8u16-license]: https://github.com/simdutf/simdutf/blob/cf8715fad4d55c87aad3006a9a82531f740605b8/benchmarks/competition/u8u16/COPYRIGHT
[single-source]: https://github.com/simdutf/is_utf8/blob/11f61076f87fcec3ba7880ac9b7f1bffca0c45f9/src/is_utf8.cpp
[range-source]: https://github.com/protocolbuffers/utf8_range/blob/1d1ea7e3fedf482d4a12b473c1ed25fe0f371a45/utf8_validity.cc
[range-api]: https://github.com/protocolbuffers/utf8_range/blob/1d1ea7e3fedf482d4a12b473c1ed25fe0f371a45/utf8_range.h
[range-build]: https://github.com/protocolbuffers/utf8_range/blob/1d1ea7e3fedf482d4a12b473c1ed25fe0f371a45/CMakeLists.txt
[fastvalidate-readme]: https://github.com/lemire/fastvalidate-utf-8/blob/c0a5f7ee26addce8c76a5c98b1120710db4060cb/README.md
[lut-decoder]: https://github.com/stgatilov/utf8lut/blob/782b76000a0296aeb7252d2bc0d979c94cab3d74/src/core/DecoderProcess.h
[lut-table]: https://github.com/stgatilov/utf8lut/blob/782b76000a0296aeb7252d2bc0d979c94cab3d74/src/core/DecoderLut.h
[lut-buffer]: https://github.com/stgatilov/utf8lut/blob/782b76000a0296aeb7252d2bc0d979c94cab3d74/src/buffer/BufferDecoder.h
[lut-initialization]: https://github.com/stgatilov/utf8lut/blob/782b76000a0296aeb7252d2bc0d979c94cab3d74/src/core/DecoderLut.cpp#L128-L134
[range-c-source]: https://github.com/protocolbuffers/utf8_range/blob/1d1ea7e3fedf482d4a12b473c1ed25fe0f371a45/range2-sse.c
