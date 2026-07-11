# UndefinedBehaviorSanitizer (unreachable from D)

The survey's **documented-absence page**: UBSan is a real, mature LLVM tool with a
40-check catalog, and it is reachable from **no** D compiler — LDC, GDC, or DMD. The
absence is not a gap in this survey; it _is_ the finding, and it falls straight out of
where UBSan's checks are emitted.

| Field                          | Value                                                                                                                 |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| Tool                           | UndefinedBehaviorSanitizer (UBSan), LLVM `compiler-rt` (`lib/ubsan`, `lib/ubsan_minimal`)                             |
| [Instrumentation locus][locus] | **clang CodeGen only** (`CGExpr.cpp` `EmitCheck` sites) — **no LLVM IR pass** for a non-clang frontend to borrow      |
| Reachable from D               | **None.** LDC (no `-fsanitize=undefined`), GDC (accepts the flag, emits no D-level checks), DMD (no sanitizer flags)  |
| Runtime on this box            | GCC `libubsan.so.1` present (156 dynamic symbols) — the _runtime_ exists; the _instrumentation_ does not              |
| Check catalog                  | **40** `UBSAN_CHECK`s (`lib/ubsan/ubsan_checks.inc`)                                                                  |
| Versions                       | LDC 1.41.0 · GDC 11.5.0 (`nixos-25.05`) · DMD 2.112.1 · source read compiler-rt [`73802c2e`][llvm-src]                |
| Verification                   | `[source-verified]` (LDC/DMD flag sets, compiler-rt architecture) + `[hw-verified: x86_64-linux]` (the GDC probe, E8) |

> [!IMPORTANT]
> **This page documents an absence rigorously, not a tool in use.** Every "unreachable"
> claim below carries a source locator or a hardware transcript. The hardware facts were
> recorded on **Linux 6.18.26**, **AMD Ryzen 9 7940HX**, with **LDC 1.41.0**, **DMD
> 2.112.1**, and **GDC 11.5.0** (`nixos-25.05`); the compiler-rt source is read at
> HEAD [`73802c2e`][llvm-src].

---

## Overview

### What UBSan is

UBSan makes C/C++ undefined behaviour trap at the point it occurs. It is a **check
catalog**, not a shadow-memory tool: clang emits an inline test at each candidate site
plus a call to a `__ubsan_handle_*` runtime handler on failure. At the pinned tree there
are **40** checks ([`lib/ubsan/ubsan_checks.inc:18-75`][llvm-src]) `[source-verified]` —
including null-pointer-use, pointer-overflow, misaligned-pointer-use, signed/unsigned
integer overflow, integer and float divide-by-zero, invalid (out-of-range) shift base and
exponent, out-of-bounds array index, `float-cast-overflow`, `invalid-bool-load`,
`invalid-enum-load`, `function-type-mismatch`, and the vptr `dynamic-type-mismatch`.
Reachability, alignment, and value-domain UB is its remit; it is orthogonal to the
addressability model of [ASan][asan] and the definedness model of
[`memcheck`/MSan][definedness].

### The minimal runtime

Beside the full runtime is a production-oriented **minimal runtime**
([`lib/ubsan_minimal/ubsan_minimal_handlers.cpp`][llvm-src]): one
`__ubsan_handle_*_minimal` handler per check that writes a one-line
`ubsan: <check> by 0x<pc>` via `write(2)`, dedups on a fixed PC array (`kMaxCallerPcs =
20`), and does no symbolization, no flag parsing, and no `vptr` checking — enabled with
`-fsanitize-minimal-runtime` ([`clang/docs/UndefinedBehaviorSanitizer.rst:265-268`][clang-ubsan]):

> "There is a minimal UBSan runtime available suitable for use in production environments.
> This runtime has a small attack surface. It only provides very basic issue logging and
> deduplication, and does not support `-fsanitize=vptr` checking."

`[source-verified]`

### Design philosophy: checks live in the frontend, not the optimizer

This is the crux of the whole page. Unlike [ASan][asan], [TSan][tsan], and MSan — which
are **LLVM IR passes** registered at the optimizer tail and therefore inherited by _any_
LLVM frontend — UBSan's checks are emitted by **clang's CodeGen** as it lowers C/C++
expressions to IR ([`clang/lib/CodeGen/CGExpr.cpp`][llvm-src] `EmitCheck` sites), because
they need the C/C++-level type, signedness, and expression structure that only the
frontend has. `llvm/lib/Transforms/Instrumentation/` contains **no UBSan pass** — its only
frontend-independent check, `BoundsChecking.cpp` (`-fsanitize=local-bounds`), is a
separate, narrower thing and is likewise not plumbed in LDC. A frontend that is not clang
has nothing to switch on. This is the same [locus][locus] argument that makes TySan
unreachable, and it is exactly why UBSan cannot be borrowed the way ASan is.

---

## How it works

UBSan is unusual among sanitizers in having almost no runtime machinery worth surveying —
its weight is entirely in the ~40 frontend check sites. Each site, when a check fails,
calls into `libubsan` (or the minimal runtime), which formats and either logs-and-continues
(`halt_on_error` is **false** by default for UBSan) or aborts under `-fsanitize-trap`. The
runtime **does** exist on this box: GCC ships `libubsan.so.1` with 156 dynamic symbols,
the full `__ubsan_handle_*` set, so the missing half is only the instrumentation, never the
runtime. `[hw-verified: x86_64-linux]`

---

## The seven concerns

The concern order is fixed across the survey. For UBSan the second concern _is_ the page,
and the rest are explicit non-applicabilities — because there is no instrumentation for D
to control, capture, symbolize, or integrate.

### Defect classes and blind spots

**Concern 1 — a rich catalog D reaches by other means, with a residual gap list.** The 40
checks are the defect classes UBSan _would_ catch. In D, the most common ones are already
covered by the **language**, not a sanitizer: array bounds are checked and throw
`RangeError` (removed only by `-boundscheck=off`), asserts and contracts fire with
`-checkaction=context`, `@safe` forbids the pointer arithmetic that reaches most
out-of-bounds UB, and — decisively — **signed integer overflow is _defined_ two's-complement
wrap in D, not undefined behaviour**, so UBSan's signed/unsigned-overflow checks have no D
semantics to enforce. What remains genuinely **unchecked** in D, and would be UBSan's to
catch:

- **out-of-range shifts** — shifting by ≥ the operand width is unchecked; `1 << 65`
  executes with the hardware's masking behaviour rather than a diagnostic
  `[hw-verified: x86_64-linux]` (E8).
- **`int.min / -1`** and integer divide-by-zero — these trap as a hardware `SIGFPE`
  (shell exit 136), not a UBSan report `[hw-verified: x86_64-linux]` (E8).
- **misaligned pointer use** and **object-size** violations reached through `.ptr` past
  what `@safe` forbids.
- **invalid `bool`/`enum` loads** from `union` type-punning, and **`void`-initialized
  reads** — a _definedness_ problem that belongs to [`memcheck`/MSan][definedness]
  territory, not UBSan's.

So the catalog is partly redundant with D's language checks and partly a real, uncovered
slice — but either way it is out of reach (concern 2).

### Instrumentation model and recompile scope

**Concern 2 — the entire finding: UBSan is unreachable from every D compiler.** Three
independent walls, each source- or hardware-verified:

- **LDC has no UBSan mode.** `-fsanitize=` accepts exactly
  `address, fuzzer, leak, memory, thread` ([`driver/cl_options_sanitizers.cpp:182-188`][ldc-src],
  a `StringSwitch`; the binary rejects `undefined`), and architecturally there is nothing
  to plumb: UBSan is clang-CodeGen-only and `llvm/lib/Transforms/Instrumentation/` has no
  UBSan pass (only the unrelated, also-unplumbed `BoundsChecking.cpp`). The sanitizer
  option logic is byte-identical between v1.41.0 and the checked-out v1.42.0-91 — this is
  not a version accident. `[source-verified]`
- **GDC accepts the flag but emits no D-level checks.** GDC 11.5 accepts
  `-fsanitize=undefined` and, once GCC 15.2's `libubsan` is lent to the link, produces a
  binary containing **exactly one** `__ubsan_handle_*` call site — a
  `__ubsan_handle_load_invalid_value` inside GDC's own `gdc.dso_ctor`/`gdc.dso_dtor`
  module-registry glue, **none in user functions**. `shiftBy(1, 65)` and `int.min / -1`
  run unchecked (the latter dies `SIGFPE`), and a `union`-punned invalid `bool` load is
  not reported. `[hw-verified: x86_64-linux]` (E8). Generalizing beyond this box, a GitHub
  code search over `gcc-mirror/gcc` (default branch, 2026-07-11) finds **zero** matches for
  `ubsan` or `flag_sanitize` under `gcc/d/` — against **18** `ubsan` matches under
  `gcc/cp/` as a control — so the GDC D frontend has no sanitizer-conditional
  instrumentation at all; only frontend-independent GIMPLE-level checks in compiler glue
  can appear. `[source-verified]`
- **DMD has nothing.** `compiler/src/dmd/cli.d` has 120 `Option(` entries and **zero**
  matches for "sanitize"; `dmd -fsanitize=address` errors "unrecognized switch". Valgrind
  (no recompilation) is DMD's only sanitizer-family path, and Valgrind has no UB checker.
  `[source-verified + hw-verified: x86_64-linux]` (see [d-toolchain.md][d-toolchain]).

There is no recompile scope to discuss, because there is no instrumentation to recompile.

### D and druntime interaction

**Concern 3 — not applicable.** No UBSan instrumentation exists to interact with druntime,
the GC, or fibers. What D offers _in place of_ UBSan is a language-level story — bounds
checks, `-checkaction=context`, `@safe`, `in`/`out` contracts, and defined integer wrap —
covered under concern 1; it is not a UBSan interaction, and the residual gaps there are
what a definedness tool ([`memcheck`][valgrind]) or a future emitter (below) would have to
carry.

### Runtime control and report capture

**Concern 4 — not applicable; the runtime exists but nothing feeds it.** There is no D
build that emits `__ubsan_handle_*` calls, so `UBSAN_OPTIONS`, the `__ubsan_on_report`
weak hook, and `libubsan`'s report machinery are all inert from D. The one concrete fact
worth recording is that GCC's `libubsan.so.1` **is installed** on this box (concern 1's
156-symbol runtime), so _if_ a D compiler ever emitted checks, the capture surface would be
present without a new dependency. `[hw-verified: x86_64-linux]`

### Symbolization and suppressions

**Concern 5 — not applicable.** With no instrumentation there are no reports to symbolize
and no findings to suppress. (Were checks ever emitted, the same no-D-demangling caveat and
the same `-fsanitize-blacklist` / `SpecialCaseList` opt-out that [ASan][asan] documents
would apply, since both are shared `compiler-rt` machinery.)

### Test-runner integration semantics

**Concern 6 — not applicable.** There is nothing for a test runner to integrate: no per-test
attribution, no [report windowing][report-windowing], no [wrapper-and-parse][wrapper-and-parse]
sink, because no D test binary produces a UBSan finding. A `--sanitize=undefined` runner mode
is not implementable on any current D compiler.

### Platform, toolchain, and overhead

**Concern 7 — unreachable on every compiler and platform; a C/C++-only tool.** The matrix
cell is uniform: `-fsanitize=undefined` is a documented GCC and clang capability for
C/C++/Objective-C (GCC's set: `shift`, `null`, `bounds`, `alignment`,
`signed-integer-overflow`, `float-divide-by-zero`, `object-size`, `pointer-overflow`,
`builtin`, … `[literature]`), and reachable from **no** D frontend on **any** platform.
There is no overhead to measure because there is no D build to run.

---

## If UBSan-for-D mattered: what it would take

Two paths exist, both surveyed here so the [comparison][comparison] and
[proposal][proposal] can weigh them:

1. **Emit the checks in LDC's `gen/`.** Because the checks are frontend work, closing the
   gap means teaching LDC's code generator to emit the ~40 `EmitCheck`-style tests and the
   `__ubsan_handle_*` calls at the right IR sites for D operations — mirroring clang's
   `CGExpr.cpp`. This is a large, ongoing effort tracking a moving check catalog, and it
   duplicates semantic decisions D partly resolves differently (defined integer wrap).
2. **Lean on what D and the survey's other tools already give.** Bounds → `RangeError`,
   `@safe`, `-checkaction=context`, and contracts cover the common cases; the definedness
   residue (`void`-init reads, `union` puns) is [`memcheck`][valgrind]'s natural remit; the
   addressability residue is [ASan][asan]'s. The genuinely uncovered UBSan-specific slice —
   out-of-range shifts, `int.min / -1`, misalignment — is small and could be addressed with
   targeted language checks rather than a full sanitizer.

The survey's recommendation follows the evidence: the UBSan column in
[comparison.md][comparison] reads **"unreachable, all compilers"** `[hw-verified:
x86_64-linux]`, and the residual gap is better closed by D language checks plus Valgrind's
definedness than by porting UBSan into LDC.

---

## Strengths

_(Of UBSan as a tool — the value D forgoes.)_

- **A precise catalog of value-domain and reachability UB** — 40 checks covering shifts,
  alignment, null, divide-by-zero, invalid loads, and vptr mismatches, at the exact site.
- **A minimal, production-safe runtime** — one-line logging with a tiny attack surface,
  usable in shipping binaries where ASan cannot go.
- **Low, targeted overhead** — inline checks only where a candidate operation occurs, with
  no shadow memory and no allocator interception.

## Weaknesses

_(From D's vantage — why it is out of reach.)_

- **Frontend-locked** — emitted in clang CodeGen with no IR pass, so no non-clang frontend
  (LDC, GDC's D frontend, DMD) can reach it. This is architectural, not a packaging gap.
- **Partly redundant with D semantics** — D's defined integer wrap and language bounds
  checks already cover the highest-value UBSan classes, shrinking the payoff of a port.
- **Minimal runtime has no symbolization or `vptr`** — logging-and-dedup only, so even the
  production mode is coarse.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                     | Trade-off                                                                                     |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Emit checks in clang CodeGen, not an LLVM IR pass          | Checks need C/C++ type, signedness, and expression structure the frontend has | No non-clang frontend can borrow them — **unreachable for D** (the page's central finding)    |
| Ship a separate minimal runtime                            | A small-attack-surface build usable in production                             | No symbolization, no flag parsing, no `vptr` — logging and dedup only                         |
| D defines signed integer overflow as two's-complement wrap | Portable, predictable arithmetic                                              | UBSan's overflow checks are moot for D, but out-of-range shifts / `int.min/-1` stay unchecked |
| D bounds-checks arrays in the language (`RangeError`)      | Catches the most common out-of-bounds without any sanitizer                   | `-boundscheck=off` removes it and `.ptr` sidesteps it — that residue is [ASan][asan]'s        |

---

## Sources

- LLVM `compiler-rt` / clang at [`73802c2e`][llvm-src] — `lib/ubsan/ubsan_checks.inc`
  (the 40-check catalog), `lib/ubsan_minimal/ubsan_minimal_handlers.cpp` (the minimal
  runtime), `clang/lib/CodeGen/CGExpr.cpp` (`EmitCheck` sites),
  `llvm/lib/Transforms/Instrumentation/` (no UBSan pass; `BoundsChecking.cpp` only).
- clang docs — [UndefinedBehaviorSanitizer][clang-ubsan] (the minimal-runtime quote, the
  check list).
- LDC at [`v1.41.0`][ldc-src] — `driver/cl_options_sanitizers.cpp:182-188` (the accepted
  `-fsanitize=` set, no `undefined`).
- DMD 2.112.1 — `compiler/src/dmd/cli.d` (zero "sanitize" options); GDC 11.5.0 hardware
  probe (E8: one `__ubsan_handle_*` site in module glue, none in user code; `gcc/d`
  code-search null result) — full transcripts in [d-toolchain.md][d-toolchain].
- Shared vocabulary: [concepts.md][concepts] ([instrumentation locus][locus],
  [definedness vs addressability][definedness], [report windowing][report-windowing],
  [wrapper-and-parse][wrapper-and-parse]).

<!-- References -->

[index]: ./
[concepts]: ./concepts.md
[locus]: ./concepts.md#instrumentation-locus
[definedness]: ./concepts.md#definedness-vs-addressability
[report-windowing]: ./concepts.md#report-windowing
[wrapper-and-parse]: ./concepts.md#wrapper-and-parse
[asan]: ./asan.md
[tsan]: ./tsan.md
[valgrind]: ./valgrind.md
[d-toolchain]: ./d-toolchain.md
[comparison]: ./comparison.md
[proposal]: ./integration-proposal.md
[llvm-src]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[ldc-src]: https://github.com/ldc-developers/ldc/tree/v1.41.0
[clang-ubsan]: https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
