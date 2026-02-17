# Parallel Algebraic Effects

Research status of combining algebraic effect handlers with multicore parallel execution.

**Last reviewed:** February 16, 2026.

---

## Why This Is Hard

Classic handler implementations are naturally sequential:

1. an operation is performed
2. the current continuation is captured
3. one handler invocation decides how to resume

This model is elegant, but it tends to serialize control flow around handler boundaries.

---

## Key Breakthrough: Parallel Algebraic Effect Handlers (ICFP 2024)

The ICFP 2024 paper introduces `lambda^p`, a calculus that combines effect handlers with parallel computation structure.

Core contribution:

- makes parallel handling a first-class semantic target instead of an ad hoc runtime trick
- provides a formal basis for deterministic reasoning about parallel resumptions
- includes a Haskell implementation artifact

This paper is the clearest starting point for "handlers + parallelism" as a principled research area.

---

## 2025 Follow-Up Direction

The POPL 2025 paper **Asymptotic Speedup via Effect Handlers** pushes the story further:

- handlers are not only an abstraction mechanism
- under the right structure, they can support provable complexity improvements

Together with `lambda^p`, this reframes handlers from "possibly slower abstraction" to "potential algorithmic tool" in parallel settings.

---

## Relationship to Mainstream Runtimes

### OCaml 5

OCaml 5 provides native effect handlers and multicore runtime support, but production libraries are still primarily optimized around practical structured concurrency and I/O, not full parallel handler calculi.

### GHC / Haskell

Delimited continuation primops enable experimentation with continuation-heavy effect libraries, but parallel algebraic handlers are still largely a research frontier rather than a settled production pattern.

### WebAssembly

Typed continuation work (WasmFX / stack-switching proposals) could become an important target substrate for cross-language implementations of parallel effect handlers.

---

## Current Research Questions

1. Which handler laws guarantee deterministic parallel composition?
2. How should resource-sensitive effects (affine/linear/temporal) interact with parallel resumptions?
3. Which compilation pipelines preserve both semantics and multicore performance?
4. How much runtime support is required versus achievable by compilation alone?

---

## Sources

- [Parallel Algebraic Effect Handlers (ICFP 2024)](https://doi.org/10.1145/3674651)
- [Asymptotic Speedup via Effect Handlers (POPL 2025)](https://doi.org/10.1145/3704871)
- [Retrofitting Effect Handlers onto OCaml (PLDI 2021)](https://doi.org/10.1145/3453483.3454039)
- [OCaml release index](https://ocaml.org/releases/)
- [GHC 9.6.1 release notes (delimited continuation primops)](https://downloads.haskell.org/~ghc/9.6.5/docs/users_guide/9.6.1-notes.html)
- [Continuing WebAssembly with Effect Handlers (OOPSLA 2023)](https://doi.org/10.1145/3622814)
