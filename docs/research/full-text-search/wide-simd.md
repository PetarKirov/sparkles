# Wide SIMD — AVX-512, SVE2, and portable vectorisation

The acceleration question Sparkles can actually act on. Unlike the GPU and FPGA
pages, everything here is available today, on the hardware this repository
already builds for.

> **Last reviewed:** August 28, 2026.

---

## What the field actually vectorises

Not the automaton. Across every engine surveyed, SIMD is applied to the same two
things:

1. **Literal candidate finding** — [memchr's packed pair][prefilters] probing two
   rare bytes across a vector at a time; [Teddy][multi] shuffling nibble-indexed
   masks for a small literal set.
2. **Byte classification and validation** — UTF-8 validation, line-terminator
   scanning, case folding.

[Vectorscan][vectorscan] is the exception that proves it: its Glushkov
decomposition exists precisely so that the _literal_ parts of a pattern can run in
SIMD and only the residue reaches an automaton.

That is [thesis T1][index] restated as an engineering fact: **the field vectorises
the prefilter, not the engine.**

## The three-way portability problem, and its answers

A vectorised routine has to answer three questions. The field has converged on
answers for all three, and this repository has none of them wired up — see the
[baseline][baseline].

**Which ISA at compile time?** [`intel-intrinsics`][ii] (v1.14.9,
`14477c6bcadea79c5b71085dec6ddf73ffb9c60c`) is D's answer: one `_mm_` source
compiling under DMD, LDC and GDC, and — the property that matters here —
**targeting AArch64 at full speed without code change**. Coverage runs MMX
through SSE4.2 plus BMI2, AVX, F16C and AVX2. `[source-verified]`

[Vectorscan][vectorscan] solves the same problem with [SIMDe][simde], which
emulates one ISA's intrinsics on another. Same strategy, different community.

**Which ISA at run time?** `cpuid`. [hypergrep][hypergrep] demonstrates the whole
thing in about forty lines — `__cpuid(1, …)` checking `bit_SSE4_2`, `bit_AVX2`,
and the AVX-512 bits, then selecting among Hyperscan's ISA-specialised engines.
`[source-verified]`

D has this in the standard library. Druntime's `core.cpuid` reports `sse41`,
`sse42`, `avx`, `avx2`, and **its accessors compile clean under `@safe nothrow
@nogc`** — verified on this host `[host-verified: x86_64-linux]`.

**How is the code multi-versioned?** This is the part nobody makes cheap.
`intel-intrinsics` picks its ISA at _compile_ time (`-mattr=+avx2` under LDC
above SSE2), so one binary that uses AVX2 where available means compiling the
same routine more than once and dispatching between the copies. [ucg][tail]
shipped multi-versioned SSE 4.2 builds; ugrep exposes `--disable-sse2` and
`--disable-avx2` build switches. **The dispatch is cheap; the multi-versioning is
the cost.**

## Is AVX-512 worth targeting?

Two data points, pointing the same way for this repository:

- **[ugrep][ugrep] targets it** (`--disable-avx2` disables "AVX2 and AVX512BW"),
  so it is a real option in a maintained tool. `[source-verified]`
- **Neither of this repository's CI runner classes offers it.** `ubuntu-latest`
  and `macos-latest` are x86-64-v3-ish and aarch64 respectively, and
  `intel-intrinsics` does not cover AVX-512 at all.

So the honest answer is **no, not now**: an AVX-512 path could not be tested in CI
and could not be written through the portability layer. SSE4.2/AVX2 on x86-64 and
NEON on aarch64 — both of which `intel-intrinsics` covers from one source — are
the reachable target.

## SVE2 and the scalable model

ARM's SVE2 is _vector-length agnostic_: the same instructions run on 128- to
2048-bit registers, with the length discovered at run time. That removes the
multi-versioning problem on ARM entirely — one binary, any width — and it is why
Vectorscan's SVE2 port is called out separately in its README as ongoing work.

For Sparkles it is future context rather than an option: `intel-intrinsics` maps
`_mm_` onto NEON, not SVE2, and Apple Silicon does not implement SVE2.

## What this catalog concluded

**A scalar-first implementation with a vectorisation-ready layout**, which is
already `sparkles:fuzzy`'s stated posture, and exactly one place where SIMD would
pay first: the **packed-pair literal prefilter**, over a byte-frequency table
derived from this repository's own corpus.

If and when that is written:

1. Write it scalar, measured, and correct. It is already fast enough to ship.
2. Vectorise through `intel-intrinsics`, so x86-64 and aarch64 come from one
   source.
3. Add `core.cpuid` behind a capability surface on `sparkles.base.hw_caps`, which
   is where "what can this CPU do" belongs and currently has no answer.
4. Multi-version only the routine that measurement says needs it.

Steps 3 and 4 are the join the baseline records as missing. Neither half is hard;
what is absent is the decision to build them, and no prefilter existing yet is a
perfectly good reason not to have made it.

## Sources

`[source-verified]`: [`intel-intrinsics`][ii] README and `source/inteli/`
(compiler matrix, ISA coverage, AArch64 guarantee); [hypergrep][hypergrep]
`src/cpu_features.cpp`; [ugrep][ugrep] `README.md` build switches;
[Vectorscan][vectorscan] `README.md` (SIMDe, SVE2). `[host-verified:
x86_64-linux]`: druntime `core.cpuid` attributes and reported capabilities.
Algorithm-level SIMD is in [literal-prefilters][prefilters] and
[multi-pattern][multi]; Teddy internals in [`parsing/hyperscan.md`][hs].

<!-- References -->

[ii]: https://github.com/AuburnSounds/intel-intrinsics/tree/14477c6bcadea79c5b71085dec6ddf73ffb9c60c
[simde]: https://github.com/simd-everywhere/simde
[prefilters]: ./literal-prefilters.md
[multi]: ./multi-pattern.md
[vectorscan]: ./vectorscan.md
[hypergrep]: ./hypergrep.md
[ugrep]: ./ugrep.md
[tail]: ./grep-long-tail.md
[baseline]: ./sparkles-baseline.md
[index]: ./index.md
[hs]: ../parsing/hyperscan.md
