# Scala 3 Capabilities and Capture Checking

Scala 3 is exploring capability-based effect reasoning at the language level, centered on context parameters/functions and experimental capture checking.

**Last reviewed:** February 16, 2026.

| Field                      | Value                                                                                                       |
| -------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Language                   | Scala 3                                                                                                     |
| Feature status             | Experimental                                                                                                |
| Official docs              | [Scala 3 experimental features index](https://docs.scala-lang.org/scala3/reference/experimental/index.html) |
| Capture checking reference | [Capture Checking](https://docs.scala-lang.org/scala3/reference/experimental/cc.html)                       |

---

## What This Is (and Is Not)

Scala capabilities are a language-level route to effect/capability tracking.

- **Is:** static tracking of captured capabilities through types
- **Is not (yet):** a finalized built-in algebraic effect-handler system in mainstream Scala

This work is best understood as capability discipline and effect reasoning infrastructure, still in active evolution.

---

## Current Status (as of February 16, 2026)

- Scala 3.8 is released (January 2026 line), and capture-checking work is highlighted in release communication.
- Capture checking remains under the experimental feature framework.

Sources:

- [Scala 3.8 release announcement (January 21, 2026)](https://www.scala-lang.org/blog/2026/01/21/scala-3.8.html)
- [Scala 3 experimental feature index](https://docs.scala-lang.org/scala3/reference/experimental/index.html)
- [Capture Checking reference](https://docs.scala-lang.org/scala3/reference/experimental/cc.html)

---

## Core Mechanisms

### 1. Context Parameters and Context Functions

Scala's `using` / context-function machinery supports implicit capability passing with direct-style call syntax. Context functions (`?=>`) enable threading capabilities through call chains without explicit plumbing:

```scala
// A capability for performing I/O
trait IO:
  def println(s: String): Unit
  def readLine(): String

// Using a capability via context parameter
def greet(using io: IO): Unit =
  io.println("Hello, " + io.readLine())

// Context function type: IO is passed implicitly
type Effectful[A] = IO ?=> A

def program: Effectful[Unit] =
  // IO capability is implicitly available
  println("hello")
```

Source: [Context Functions](https://docs.scala-lang.org/scala3/reference/contextual/context-functions.html)

### 2. Capture Checking

Capture checking annotates types with the capabilities they capture, preventing capability escape and improving local reasoning about effects:

```scala
import language.experimental.captureChecking

// This closure captures the 'io' capability
val f: (Int => Unit)^{io} = (x: Int) => io.println(x.toString)
```

The `^{io}` annotation indicates that `f` captures the `io` capability. The type system ensures that:

1. Capabilities do not escape their intended scope
2. Functions that perform effects are properly annotated
3. Pure functions are guaranteed to capture no capabilities

Source: [Capture Checking](https://docs.scala-lang.org/scala3/reference/experimental/cc.html)

### 3. Boundary / Break for Structured Non-Local Exits

Available since Scala 3.3.0, `boundary` and `break` provide non-local returns -- a stepping stone toward full algebraic effects:

```scala
import scala.util.boundary
import boundary.break

def findIndex(xs: List[Int], target: Int): Int =
  boundary:
    for (x, i) <- xs.zipWithIndex do
      if x == target then break(i)
    -1
```

`boundary` defines a scope and `break` exits it, analogous to an effect handler and an effect operation.

Source: [Dropped: Nonlocal Returns (use `scala.util.boundary`)](https://docs.scala-lang.org/scala3/reference/dropped-features/nonlocal-returns.html)

---

## Why It Matters for Effect Systems

Scala's capability direction is important because it shifts part of effect reasoning from library encodings into the language type system.

Potential upside:

- stronger static guarantees for authority/effect usage
- direct-style ergonomics without mandatory monadic wrappers

Current limitation:

- full algebraic handlers with resumptions are still primarily a research/library domain, not a stabilized core Scala language feature.

---

## Strengths

- Language-level integration (not purely library-level discipline)
- Strong alignment with capability-based security/reasoning ideas
- Promising path for direct-style effect-safe APIs

## Limits

- Experimental and evolving
- Tooling and ecosystem practices still catching up
- Semantics and ergonomics are not yet "finished" in the way mature effect libraries are

---

## Sources

- [Scala 3.8 release announcement (2026-01-21)](https://www.scala-lang.org/blog/2026/01/21/scala-3.8.html)
- [Scala 3 experimental features index](https://docs.scala-lang.org/scala3/reference/experimental/index.html)
- [Capture Checking (Scala 3 reference)](https://docs.scala-lang.org/scala3/reference/experimental/cc.html)
- [Context Functions (Scala 3 reference)](https://docs.scala-lang.org/scala3/reference/contextual/context-functions.html)
- [Dropped: Nonlocal Returns (use `scala.util.boundary`)](https://docs.scala-lang.org/scala3/reference/dropped-features/nonlocal-returns.html)
- [Scala contributors discussion: capabilities questions](https://contributors.scala-lang.org/t/questions-regarding-capabilities/7223)
