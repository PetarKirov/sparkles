# Scala 3 Capabilities and Direct-Style Effects

An experimental approach to effect tracking built into the Scala 3 language itself, using context functions for ergonomic effect passing and capture checking for type-level safety. This represents Scala's long-term vision for effects beyond monadic IO.

| Field        | Value                                                   |
| ------------ | ------------------------------------------------------- |
| Language     | Scala 3 (experimental features)                         |
| Status       | Experimental; actively researched; not production-ready |
| Key Authors  | Martin Odersky, EPFL LAMP team                          |
| Project Name | Caprese (CAPability-based RESilent Effects)             |
| Approach     | Context functions + capture checking + boundary/break   |

---

## Overview

### What It Solves

Scala 3 Capabilities aim to unify permissions, effects, and resources under a single concept: capabilities. The goal is to enable direct-style programming -- writing code that looks imperative but retains the reasoning benefits of functional programming -- with compile-time effect tracking built into the language rather than provided by a library.

### Design Philosophy

Capabilities are the missing link between functional and imperative programming. Traditional approaches require either monads (ergonomically costly) or unchecked side effects (unsafe). Capabilities allow passing effect tokens implicitly through context functions, with the type system tracking which capabilities are captured and where.

---

## Core Concepts

### What Are Capabilities?

A capability is a value that grants permission to perform a specific effect. Having access to a capability value means you can perform the associated effect. The type system tracks which capabilities flow through the program.

```scala
// A capability for performing I/O
trait IO:
  def println(s: String): Unit
  def readLine(): String

// Using a capability via context parameter
def greet(using io: IO): Unit =
  io.println("Hello, " + io.readLine())
```

### Context Functions

Context functions (using `?=>` syntax) enable implicit capability passing:

```scala
type Effectful[A] = IO ?=> A

def program: Effectful[Unit] =
  // IO capability is implicitly available
  println("hello")  // resolved via context function
```

This eliminates the tedium of threading capabilities through long call chains.

### Boundary and Break

Available since Scala 3.3.0, `boundary` and `break` provide non-local returns:

```scala
import scala.util.boundary
import boundary.break

def findIndex(xs: List[Int], target: Int): Int =
  boundary:
    for (x, i) <- xs.zipWithIndex do
      if x == target then break(i)
    -1
```

This is a stepping stone toward full algebraic effects -- `boundary` defines a scope and `break` exits it, analogous to an effect handler and an effect operation.

---

## Capture Checking

### Overview

Capture checking is an experimental feature that modifies Scala's type system to track references to capabilities in values. It can be enabled via:

```scala
import language.experimental.captureChecking
```

### How It Works

Capture checking annotates types with the capabilities they capture:

```scala
// This closure captures the 'io' capability
val f: (Int => Unit)^{io} = (x: Int) => io.println(x.toString)
```

The `^{io}` annotation indicates that `f` captures the `io` capability. The type system ensures that:

1. Capabilities do not escape their intended scope
2. Functions that perform effects are properly annotated
3. Pure functions are guaranteed to capture no capabilities

### Relationship to Effect Tracking

Capture checking provides **passive** effect tracking -- it tells you which capabilities a value has captured, which corresponds to which effects it might perform. This is complementary to context functions, which provide the mechanism for passing capabilities.

### Current Status

Capture checking is highly experimental and unstable, evolving quickly. It represents a technical breakthrough in capability-safe programming but is not yet suitable for production use.

---

## Direct-Style Effects

### The Vision

Direct-style effects, also called algebraic effects and effect handlers, allow writing code in natural imperative style while retaining the benefits of functional effect tracking:

```scala
// Direct style -- looks imperative
def processUser(id: UserId)(using db: Database, log: Logger): User =
  val user = db.getUser(id)  // no .flatMap needed
  log.info(s"Found user: $user")
  user

// vs. monadic style
def processUser(id: UserId): ZIO[Database & Logger, Error, User] =
  for
    user <- ZIO.serviceWithZIO[Database](_.getUser(id))
    _    <- ZIO.serviceWithZIO[Logger](_.info(s"Found user: $user"))
  yield user
```

### How It Works (Mechanism)

The mechanics come down to context functions:

1. **Effect declaration**: Context functions define what effects are needed
2. **Effect implementation**: Handlers provide the actual implementation
3. **Separation**: Unlike IO monads where the same type indicates both the need for effects and provides implementation, direct-style effects separate these concerns

### Runtime Support Requirements

Full direct-style effects require continuations:

- **Scala Native**: Getting first-class continuation support
- **JVM**: Project Loom provides virtual threads (a form of one-shot continuations)
- **Current limitation**: Scala 3 does not yet expose a continuation API; only `boundary`/`break` is available

---

## Two Effect Tracking Mechanisms (Caprese)

The Caprese project introduces two complementary mechanisms:

### 1. Capture Tracking (`^{...}`)

Tracks which capabilities are referenced by a value:

```scala
val f: (Int => String)^{db, log} = ???  // f captures db and log
```

### 2. Context Functions (`?=>`)

Provides ergonomic passing of capabilities as implicit parameters:

```scala
def withTransaction[A](body: Transaction ?=> A)(using db: Database): A = ???
```

These two mechanisms work together: context functions make capabilities available, and capture checking ensures they are tracked properly.

---

## Strengths

- **Language-level integration**: Effects tracked by the compiler, not a library
- **Direct style**: Code looks natural and imperative; no monadic ceremony
- **Unified concept**: Capabilities subsume permissions, effects, and resources
- **Capture safety**: Compile-time guarantee that capabilities do not escape scope
- **Gradual adoption**: Can be mixed with existing Scala code
- **Theoretical foundation**: Based on reachability types and capability-safe programming research

## Weaknesses

- **Experimental**: Not production-ready; API unstable and evolving rapidly
- **No continuation support yet**: Full algebraic effects require continuations not yet available in Scala 3
- **JVM limitations**: JVM does not natively support multi-shot continuations
- **Incomplete tooling**: IDE support, error messages, and debugging are immature
- **Unknown performance**: No benchmarks or production experience
- **Long timeline**: Scala 3.8 (Q4 2025) and 3.9 LTS (Q2 2026) are the targets; full capabilities may take longer

## Key Design Decisions and Trade-offs

| Decision                         | Rationale                                               | Trade-off                                                      |
| -------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------- |
| Language-level (not library)     | Deeper integration; better ergonomics; compiler support | Slower iteration; tied to language release cycle               |
| Context functions for passing    | Implicit capability threading; no explicit plumbing     | Less visible; can be confusing which capabilities are in scope |
| Capture checking annotations     | Precise tracking of capability references               | New annotation syntax; learning curve; verbose types           |
| Boundary/break as stepping stone | Available now; useful without full continuations        | Limited expressiveness compared to full algebraic effects      |
| JVM virtual threads for runtime  | Leverages Project Loom; one-shot continuations          | No multi-shot continuations; limited backtracking support      |

---

## Academic Foundations

### Key Papers and Talks

- **"Typestate via Revocable Capabilities"** (arXiv 2510.08889, 2025) -- Formalizing capabilities with revocation
- **Scala Days 2025**: Martin Odersky presented the Scala roadmap including capabilities; Bracevac and Boruch-Gruszecki demonstrated direct-style effects
- **The Scala Workshop 2025**: "Where Are We With Scala's Capabilities?" -- status report on Caprese
- **Reachability types**: The theoretical framework behind capture checking, enabling Rust-style ownership concepts in a garbage-collected language

---

## Sources

- [Capture Checking -- Scala 3 Reference](https://docs.scala-lang.org/scala3/reference/experimental/cc.html)
- [Questions regarding Capabilities -- Scala Contributors](https://contributors.scala-lang.org/t/questions-regarding-capabilities/7223)
- [Effects as Capabilities](https://nrinaudo.github.io/articles/capabilities.html) -- Nicolas Rinaudo
- [Direct-style Effects Explained](https://noelwelsh.com/posts/direct-style/) -- Noel Welsh
- [Where Are We With Scala's Capabilities?](https://2025.workshop.scala-lang.org/details/scala-2025/15/Where-Are-We-With-Scala-s-Capabilities-) -- Scala Workshop 2025
- [Scala Days 2025 coverage](https://xebia.com/blog/scala-days-2025-ai-integration/) -- Xebia
- [Scala's Gamble with Direct Style](https://alexn.org/blog/2025/08/29/scala-gamble-with-direct-style/) -- Alexandru Nedelcu
