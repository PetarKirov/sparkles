# Theseus (Haskell)

A Haskell library for sound higher-order and algebraic effects using higher-order Freer monads. Announced in early 2025 as an alternative approach to the soundness problem addressed by [heftia].

| Field         | Value                                    |
| ------------- | ---------------------------------------- |
| Language      | Haskell                                  |
| License       | BSD-3-Clause                             |
| Repository    | [github.com/jhgarner/Theseus]            |
| Documentation | [GitHub][theseus GitHub repository]      |
| Key Authors   | Sebastian Berndt                         |
| Status        | Early release (2025); active development |
| Encoding      | Higher-order Freer monad                 |

---

## Overview

### What It Solves

Theseus addresses the same problem as [heftia]: the unsound interaction between higher-order effects (like `catch`, `local`) and algebraic effects (like `NonDet`, `State`) that plagued earlier libraries like [polysemy] and [fused-effects]. While [heftia] uses the elaboration approach from the [Hefty Algebras] paper, Theseus takes a different approach using **higher-order Freer monads**.

### Design Philosophy

Theseus aims for:

1. **Sound semantics**: Correct handling of higher-order + algebraic effect combinations
2. **Order-independent interpretations**: Handler order should not produce surprising results
3. **Built-in resource safety**: Finalizers and cleanup handled correctly through `ControlFlow`

---

## Core Abstractions and Types

### Higher-Order Freer Monad

Theseus builds on the Freer monad structure but extends it to handle higher-order computations natively:

```haskell
-- Freer monad with higher-order support
newtype Freer f a

-- f is a higher-order functor describing effect operations
```

### ControlFlow for Resource Safety

A key innovation is the `ControlFlow` class that manages finalizers:

```haskell
class ControlFlow f where
  -- Ensure cleanup runs even with continuations
  finalize :: f m a -> (a -> m ()) -> f m a
```

This ensures that resources are properly cleaned up even when continuations are resumed multiple times or not at all.

### Linear Continuations

To ensure soundness and resource safety, Theseus enforces linear usage of certain suspended functions (continuations), preventing "multi-shot" violations that could leak resources or cause inconsistent state.

---

## Comparison with [heftia]

| Feature        | Theseus                    | [heftia]              |
| -------------- | -------------------------- | --------------------- |
| **Soundness**  | Yes (Consistent semantics) | Yes (via Elaboration) |
| **Mechanism**  | Higher-order Freer         | Hefty Algebras        |
| **Complexity** | Moderate                   | Higher (Two-phase)    |
| **Finalizers** | Built-in (ControlFlow)     | Via base monad        |

---

## Sources

- [theseus GitHub repository]
- [Theseus announcement on Haskell Discourse]
- [Hefty Algebras (POPL 2023)]

<!-- References -->

[heftia]: haskell-heftia.md
[polysemy]: haskell-polysemy.md
[fused-effects]: haskell-fused-effects.md
[Hefty Algebras]: papers.md
[github.com/jhgarner/Theseus]: https://github.com/jhgarner/Theseus
[theseus GitHub repository]: https://github.com/jhgarner/Theseus
[Theseus announcement on Haskell Discourse]: https://discourse.haskell.org/t/theseus-worry-free-algebraic-and-higher-order-effects/13563
[Hefty Algebras (POPL 2023)]: https://doi.org/10.1145/3571255
