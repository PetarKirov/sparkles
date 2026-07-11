# Grounding ledger — `ubsan.md`

Claim-by-claim verification of `docs/research/sanitizers/ubsan.md` (the documented-absence
page) against the pinned trees compiler-rt/clang [`llvm-project@73802c2e`], LDC
[`ldc@v1.41.0`] (read via `git show`), and DMD 2.112.1. Hardware experiment (GDC 11.5.0,
`nixos-25.05`) recorded on **Linux 6.18.26**, **AMD Ryzen 9 7940HX**, **LDC 1.41.0** /
**DMD 2.112.1**. `$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

| #   | Claim                                                                                                                                                                                                                | Type       | Source (local + locator)                                                                             | Status |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------- | ------ |
| U1  | UBSan is a **40**-check catalog (null/pointer-overflow, misalign, signed/unsigned overflow, div-by-zero, invalid shift, OOB index, float-cast, invalid bool/enum load, vptr, …)                                      | fact       | `lib/ubsan/ubsan_checks.inc:18-75`                                                                   | ✓      |
| U2  | Minimal runtime: one `__ubsan_handle_*_minimal` per check, one-line `ubsan: <check> by 0x<pc>` via `write(2)`, PC dedup `kMaxCallerPcs=20`, no symbolization/flags/vptr; `-fsanitize-minimal-runtime`                | fact       | `lib/ubsan_minimal/ubsan_minimal_handlers.cpp`; `clang/docs/UndefinedBehaviorSanitizer.rst:260-273`  | ✓      |
| U3  | Minimal-runtime quote                                                                                                                                                                                                | quote      | `clang/docs/UndefinedBehaviorSanitizer.rst:265-268` (_"There is a minimal UBSan runtime…"_ verbatim) | ✓      |
| U4  | Locus: UBSan checks emitted by **clang CodeGen** (`EmitCheck` sites); `llvm/lib/Transforms/Instrumentation/` has **no UBSan pass** (only `BoundsChecking.cpp` = `local-bounds`, also unplumbed)                      | fact       | `clang/lib/CodeGen/CGExpr.cpp`; `llvm/lib/Transforms/Instrumentation/` dir listing                   | ✓      |
| U5  | LDC `-fsanitize=` accepts exactly `address, fuzzer, leak, memory, thread` — no `undefined`; byte-identical v1.41.0 ↔ v1.42.0-91                                                                                      | fact       | `ldc@v1.41.0 driver/cl_options_sanitizers.cpp:182-188`; binary rejects `undefined`                   | ✓ (hw) |
| U6  | GDC 11.5 accepts `-fsanitize=undefined` but emits **one** `__ubsan_handle_load_invalid_value` — inside `gdc.dso_ctor`/`dso_dtor` glue, **none** in user functions; `shiftBy(1,65)` & `int.min/-1` unchecked (SIGFPE) | behavior   | W1 E8 (`nm`/`objdump`; `1<<65`, `int.min/-1`, `badbool.d`)                                           | ✓ (hw) |
| U7  | `gcc-mirror/gcc` code search (default branch, 2026-07-11): **0** `ubsan`/`flag_sanitize` under `gcc/d/`; control **18** `ubsan` under `gcc/cp/`                                                                      | fact       | W1 E8 (`gh api search/code`)                                                                         | ✓ 🌐   |
| U8  | DMD has **zero** sanitizer flags: `cli.d` = 120 `Option(`, 0 "sanitize"; `dmd -fsanitize=address` → "unrecognized switch"                                                                                            | fact       | `dmd@e6baf474 compiler/src/dmd/cli.d`; W3 claim 35                                                   | ✓ (hw) |
| U9  | GCC `libubsan.so.1` present on this box (156 dynamic syms, full `__ubsan_handle_*` set) — the runtime exists; only the instrumentation is missing                                                                    | fact       | `nm -D libubsan.so.1`; W1 claim 25                                                                   | ✓ (hw) |
| U10 | D covers the common UB classes by language: bounds → `RangeError` (off only with `-boundscheck=off`), **signed integer overflow is DEFINED wrap** (not UB), `-checkaction=context`, `@safe`, contracts               | fact       | W1 claim 24; D spec / `-boundscheck` docs                                                            | ✓      |
| U11 | Residual UBSan-specific gaps in D: out-of-range shift (`1<<65` unchecked), `int.min/-1` & int div-by-zero (SIGFPE, no diagnostic), misalign, `union` puns / `void`-init reads (→ MSan/valgrind)                      | behavior   | W1 E8 (shift/div hw); claim 24 (the MSan/valgrind residue)                                           | ✓ (hw) |
| U12 | GCC's documented `-fsanitize=undefined` set for C/C++ (`shift`, `null`, `bounds`, `alignment`, `signed-integer-overflow`, `object-size`, `pointer-overflow`, `builtin`, …)                                           | fact       | `gcc-15.1-instrumentation-options.html` (W3 `[lit]`)                                                 | ✓ 🌐   |
| U13 | Concerns 3–6 are N/A: no instrumentation exists to interact with druntime, control/capture, symbolize/suppress, or integrate into a runner                                                                           | exposition | derived from U4–U8 (no D UBSan build)                                                                | ✓      |
| U14 | Path forward: emit checks in LDC `gen/` (large, mirrors `CGExpr.cpp`) **or** lean on D language checks + Valgrind definedness; comparison column = "unreachable, all compilers"                                      | opinion    | design sketch — not implemented                                                                      | ◯      |

## Discrepancies

- **⚠ D-U1 — UBSan is NOT reachable under LDC** (register R1). The brief's framing
  ("Primary bed: LDC ASan/TSan/**UBSan** runs") assumed a UBSan mode; LDC has no
  `-fsanitize=undefined` and there is no LLVM IR pass to borrow (U4/U5). The page makes
  this its central finding. `[source-verified]`
- **⚠ D-U2 — "UBSan-for-D via GDC" is link-viable but check-empty** (register R8, partial).
  GDC accepts the flag and links `libubsan`, but emits no D-level checks — the sole
  `__ubsan_handle_*` site is compiler module-registry glue (U6), and the `gcc/d` frontend
  carries no sanitizer instrumentation at all (U7). The page states this as the GDC wall.
  `[hw-verified: x86_64-linux]` (glue site) + `[source-verified]` (code search).
- **Note — the runtime is not the blocker.** GCC ships a full `libubsan.so.1` on this box
  (U9); the absence is purely in the instrumentation half, on every D compiler. Stated in
  "How it works" and concern 4.

**Net:** 0 substantive discrepancies remaining. The absence is documented with a source
locator or hardware transcript per wall (LDC flag set, the GDC one-glue-site probe + `gcc/d`
code search, DMD's empty CLI) and one verbatim quote (the minimal-runtime paragraph). U14
(the "what it would take" path) is honestly `◯` — a design sketch, not compiled. The two ⚠
items correct the brief's UBSan-under-LDC assumption (R1) and sharpen the GDC column to
"check-empty" (R8).

<!-- References -->
