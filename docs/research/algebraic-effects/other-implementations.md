# Other Notable Effect System Implementations

A brief survey of other significant or emerging effect system implementations across various languages and platforms as of 2026.

---

## Mojo (Modular)

Mojo is designed for high-performance systems programming and AI workloads. While it does not feature a traditional algebraic effect system, its **Safety Model** is a state-of-the-art implementation of memory safety by default (Phase 1 achieved by 2026). It uses an ownership and borrowing system inspired by Rust but optimized for ease of use and parallel execution.

- **Status**: Version 1.0 released in 2026.
- **Key Feature**: Performance-first memory safety without a garbage collector.

## Verse (Epic Games)

Verse is a functional logic programming language designed for the metaverse. It features a novel effect system based on **Failure as an Effect**. In Verse, a computation can fail, and this failure is managed through a structured hierarchy of choice and backtracking.

- **Key Innovation**: Unifying logical failure with control flow.

## Links (University of Edinburgh)

Links is a research language for web programming that uses **Row-Polymorphic Algebraic Effects** to manage interaction between client, server, and database. It was one of the first languages to demonstrate that algebraic effects can unify local control flow with distributed asynchronous callbacks.

## Lean 4

Lean 4, primarily a theorem prover, has an increasingly capable programming model. It uses an **IO-based Effect System** with strong support for purely functional structures. While not algebraic in the Koka sense, its use of `do` notation and custom monads provides a highly disciplined environment for effectful code.

---

## Summary of Emerging Trends

1. **Safety First**: Languages like Mojo and Swift are integrating effect-like tracking (safety constraints) into their core systems.
2. **Parallelism**: The trend is moving toward multicore-aware effect handlers (e.g., OCaml 5, Parallel Haskell).
3. **Hardware Support**: WasmFX and GHC primops show that runtime support for continuations is becoming a standard requirement for high-performance effect systems.
