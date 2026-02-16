# Theseus (Haskell)

A next-generation Haskell effect system library introduced in January 2026, designed to provide consistent semantics for algebraic and higher-order effects regardless of interpreter ordering.

| Field       | Value                                                              |
| ----------- | ------------------------------------------------------------------ |
| Language    | Haskell                                                            |
| License     | BSD-3-Clause                                                       |
| Repository  | [github.com/jhgarner/Theseus](https://github.com/jhgarner/Theseus) |
| Key Authors | Jack Garner                                                        |
| Encoding    | Higher-order Freer Monad; ControlFlow class for finalizers         |

---

## Overview

### What It Solves

Theseus addresses the long-standing "ordering problem" in Haskell effect systems, where the behavior of higher-order effects (like `catch` or `local`) can change depending on their position in the interpreter stack relative to algebraic effects (like `NonDet`). Theseus guarantees consistent semantics regardless of how interpreters are ordered, while also providing robust support for resource management via guaranteed finalizers.

### Design Philosophy

The library is built on the principle that effect interactions should be predictable and easy to reason about locally. By using a higher-order Freer Monad and a dedicated `ControlFlow` class, Theseus ensures that effects compose soundly. It prioritizes developer experience and resource safety, offering a "worry-free" approach to complex effect interactions.

---

## Core Abstractions and Types

### Higher-Order Freer Monad

Theseus uses a generalized Freer Monad that can represent both first-order algebraic operations and higher-order scoped operations within a single unified structure. This eliminates the need for the two-phase "elaboration" required by libraries like `heftia`.

### The ControlFlow Class

The `ControlFlow` typeclass is Theseus's mechanism for managing control flow transitions and finalizers. It ensures that cleanup actions are executed even in the presence of nondeterminism, early exit, or coroutine suspension.

```haskell
class ControlFlow f where
  onControlFlow :: (forall x. m x -> n x) -> f m a -> f n a
```

---

## Key Features

### Order-Independent Interpretation

Unlike `polysemy` or `fused-effects`, where swapping `runError` and `runState` changes whether state is rolled back on error, Theseus provides mechanisms to specify desired interaction laws that are preserved regardless of the actual stack order.

### Breadth-First Nondeterminism

Theseus implements nondeterminism using a breadth-first search strategy by default, which can be more predictable than the depth-first approach used in traditional backtracking handlers.

### Linear Suspended Functions

To ensure soundness and resource safety, Theseus enforces linear usage of certain suspended functions (continuations), preventing "multi-shot" violations that could leak resources or cause inconsistent state.

---

## Comparison with heftia

| Feature        | Theseus                    | heftia                |
| -------------- | -------------------------- | --------------------- |
| **Soundness**  | Yes (Consistent semantics) | Yes (via Elaboration) |
| **Mechanism**  | Higher-order Freer         | Hefty Algebras        |
| **Complexity** | Moderate                   | Higher (Two-phase)    |
| **Finalizers** | Built-in (ControlFlow)     | Via base monad        |

---

## Sources

- [Theseus: Worry-free algebraic and higher-order effects](https://discourse.haskell.org/t/theseus-worry-free-algebraic-and-higher-order-effects/13563) (Jan 2026)
- [Theseus GitHub Repository](https://github.com/jhgarner/Theseus)
