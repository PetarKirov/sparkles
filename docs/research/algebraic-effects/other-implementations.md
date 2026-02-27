# Additional Implementations and Research Systems

Notable systems adjacent to (or directly implementing) algebraic effects beyond the primary language pages in this folder.

**Last reviewed:** February 16, 2026.

---

## Effekt

Effekt is a research language centered on effect handlers and direct-style programming.

- Focus: language-level support for handlers and effect polymorphism
- Value: good reference point for modern handler-oriented language design
- Relationship: Similar design goals to [Eff] and [Koka]

Reference: [Effekt website]

---

## Links

Links is a research language for web programming with row-polymorphic effect typing and long-running work on effect handlers.

- Focus: typed effects in client/server/database integrated programming
- Value: shows effect systems in a full-stack language setting

Reference: [Links language site]

---

## Koka (for context)

[Koka] is covered in detail in its dedicated page, but it is worth reiterating here as one of the strongest end-to-end designs:

- row-polymorphic effect types with inference
- practical compilation strategies
- active releases in the v3 line

References:

- [Koka website]
- [Koka releases]

---

## Systems-Language Direction: C + Coroutines

Recent work demonstrates effect handlers implemented in C via coroutine machinery.

- Focus: low-level implementation route without requiring a full new language runtime
- Value: broadens the portability story for handlers

Reference: [Effect Handlers for C via Coroutines (ICFP 2024)]

---

## WebAssembly Target Direction

Wasm continuation proposals and [WasmFX] work position WebAssembly as a common low-level target for effect handlers.

- Focus: typed control transfer primitives for compiled handlers
- Value: potential cross-language backend convergence

References:

- [Continuing WebAssembly with Effect Handlers (OOPSLA 2023)]
- [WebAssembly stack-switching proposal repository]

---

## Related Topics

- For systems-language implementations with virtual threads, see [Java Loom] and [Scala Ox]
- For capability-based effect tracking, see [Scala 3 Capabilities] and [Bluefin]
- For the main WebAssembly effect handler proposal, see [WasmFX]

---

## Notes

- This page intentionally excludes systems that are only loosely "effect-like" (for example, generic safety/ownership claims without handler semantics).
- For full historical context, see [Evolution of Effect Systems]; for active research, see [Key Papers].

<!-- References -->

[Eff]: eff-lang.md
[Koka]: koka.md
[WasmFX]: wasmfx.md
[Java Loom]: java-loom.md
[Scala Ox]: scala-ox.md
[Scala 3 Capabilities]: scala-capabilities.md
[Bluefin]: haskell-bluefin.md
[Evolution of Effect Systems]: evolution.md
[Key Papers]: papers.md
[Effekt website]: https://effekt-lang.org/
[Links language site]: https://links-lang.org/
[Koka website]: https://koka-lang.github.io/koka/doc/index.html
[Koka releases]: https://github.com/koka-lang/koka/releases
[Effect Handlers for C via Coroutines (ICFP 2024)]: https://doi.org/10.1145/3649836
[Continuing WebAssembly with Effect Handlers (OOPSLA 2023)]: https://doi.org/10.1145/3622814
[WebAssembly stack-switching proposal repository]: https://github.com/WebAssembly/stack-switching
