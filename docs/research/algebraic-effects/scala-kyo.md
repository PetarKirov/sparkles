# Kyo (Scala)

A powerful toolkit for Scala development based on algebraic effects, providing an open set of composable effects rather than a fixed number of effect channels. Kyo generalizes ZIO's effect rotation to support arbitrary effect types.

| Field         | Value                                                         |
| ------------- | ------------------------------------------------------------- |
| Language      | Scala 3                                                       |
| License       | Apache-2.0                                                    |
| Repository    | [github.com/getkyo/kyo](https://github.com/getkyo/kyo)        |
| Documentation | [getkyo.io](https://getkyo.io/)                               |
| Key Authors   | Flavio Brasil                                                 |
| Approach      | Algebraic effects with modular handlers; open effect channels |

---

## Overview

### What It Solves

Kyo provides an algebraic effects system that goes beyond ZIO and Cats Effect by allowing an arbitrary number of user-defined effect types, not just the fixed error and environment channels. This enables more precise and granular control over computational context. Kyo achieves this without requiring category theory concepts or cryptic operators.

### Design Philosophy

Kyo brings algebraic effects to practical Scala programming. While ZIO provides two fixed effect channels (environment R and error E), Kyo allows developers to define and compose an open set of effects tailored to their specific needs. The design is direct-style-inspired, leveraging Scala 3's type system to minimize the distinction between `map` and `flatMap`.

---

## Core Abstractions and Types

### The Pending Type (<)

Computations in Kyo are represented by the infix type `<` ("pending"):

```scala
opaque type <[+A, -S]
```

| Parameter | Meaning                                     | Variance      |
| --------- | ------------------------------------------- | ------------- |
| **A**     | Type of value produced on success           | Covariant     |
| **S**     | Set of pending effects that must be handled | Contravariant |

Examples:

```scala
val pure: Int < Any = 42                           // no pending effects
val failing: Int < Abort[String] = ???              // may abort with String
val complex: Int < (Abort[String] & Env[Config]) = ???  // multiple pending effects
```

### Contravariant Pending Effects

The contravariance of `S` is a key design insight: a computation with _more_ effects is a subtype of one with _fewer_ effects. This means:

- Pure values (`Int < Any`) can be used wherever effectful computations are expected
- `map` and `flatMap` are unified -- all values are automatically promoted to computations with zero pending effects
- Effect widening happens naturally through Scala's subtyping

### Unification of map and flatMap

```scala
val a: Int < Abort[String] = ???
val b: Int < Env[Config] = ???

// Using only map -- works like flatMap due to effect widening
val c: Int < (Abort[String] & Env[Config]) =
  a.map(x => b.map(y => x + y))
```

This removes the need to juggle between `map` and `flatMap`, allowing developers to focus on application logic.

---

## How Effects Are Declared

### Built-in Effects

Kyo provides a comprehensive set of core effects:

| Effect      | Purpose                            | Analogous To           |
| ----------- | ---------------------------------- | ---------------------- |
| `Abort[E]`  | Short-circuiting with error type E | ZIO's E channel        |
| `Env[R]`    | Dependency injection               | ZIO's R channel        |
| `IO`        | Side-effecting operations          | ZIO's IO               |
| `Async`     | Fiber scheduling, parking          | ZIO's fiber operations |
| `Resource`  | Resource lifecycle management      | ZIO's Scope            |
| `Stream[V]` | Streaming values                   | ZIO Stream             |
| `Var[V]`    | Mutable state                      | ZIO Ref                |
| `Emit[V]`   | Emitting values                    | Writer effect          |
| `Choice`    | Non-deterministic computation      | List/NonDet            |

### Custom Effects

Developers can define custom effects as new types in the `S` parameter, with corresponding handlers that remove them.

---

## How Handlers/Interpreters Work

### The handle Method

Effect handling uses a fluent API:

```scala
val a: Int < (Abort[String] & Env[Int]) =
  for
    v <- Abort.get(Right(42))
    e <- Env.get[Int]
  yield v + e

// Handle effects using handle
val b: Result[String, Int] =
  a.handle(Abort.run(_))    // Handle Abort, removing it from S
   .handle(Env.run(10))      // Handle Env, removing it from S
   .eval                     // Evaluate when S is empty

// Equivalent nested form
val c: Result[String, Int] =
  Env.run(10)(Abort.run(a)).eval
```

Each handler call removes one effect from the `S` type parameter. Once all effects are handled (S becomes `Any`), the computation can be evaluated with `.eval`.

### Handler Composition

Multiple handlers can be applied in a single `handle` call:

```scala
val result: Int =
  a.handle(
    Abort.run(_),
    Env.run(10),
    _.map(_.getOrElse(24)),
    _.eval
  )
```

### Direct Syntax

For a more imperative feel, Kyo provides `.now` and `.later`:

```scala
direct {
  val x = effectA.now    // sequence immediately
  val y = effectB.later  // preserve for later
  x + y
}
```

---

## Performance Approach

### Algebraic Effects Foundation

Kyo's performance comes from its algebraic effects architecture:

1. **No monad transformer overhead**: Effects are not stacked as transformers
2. **Minimal indirection**: Each effect handler directly processes its operations
3. **Compile-time effect resolution**: Scala 3's type system resolves effect composition at compile time

### Comparison with ZIO

Where ZIO bakes two effects (R and E) into its type and adds overhead for the fixed channels, Kyo only pays for the effects actually used. A computation with a single `Abort[String]` effect does not carry unused environment or state machinery.

### Stream Optimizations

Kyo distinguishes between pure and effectful stream operations:

- `mapPure` for `V => V1` (no effects, optimized)
- `map` for `V => V1 < S1` (effectful, more general)

While effectful `map` accepts pure functions (via automatic lifting), the `Pure` variants are optimized for the common case.

---

## Composability Model

### Open Effect Set

Unlike ZIO (fixed to R, E) or Cats Effect (fixed typeclass hierarchy), Kyo allows arbitrary effect types:

```scala
// Mix any effects freely
def program: Result < (Abort[AppError] & Env[Config] & Async & Stream[LogEntry]) = ???
```

### Effect Rotation (Generalized from ZIO)

Kyo generalizes ZIO's "effect rotation" mechanism. In ZIO, the R and E channels can be transformed independently (e.g., `mapError` transforms E without touching R). Kyo extends this to arbitrary effect channels -- each effect can be handled independently regardless of what other effects are present.

### Intersection Types for Composition

Scala 3's intersection types (`&`) provide natural syntax for combining effects:

```scala
type MyEffects = Abort[String] & Env[Config] & IO & Async
def myProgram: Result < MyEffects = ???
```

---

## Strengths

- **Open effect set**: Arbitrary number of user-defined effects, not fixed channels
- **Unified map/flatMap**: Contravariant effects eliminate the map/flatMap distinction
- **Direct style**: More natural programming feel; less monadic ceremony
- **Algebraic foundation**: Based on solid theory of algebraic effects and handlers
- **No category theory prerequisites**: Pragmatic API design
- **Cross-platform**: Supports JVM, JS, and Native via Scala 3
- **Active development**: Approaching 1.0 with stable API commitment

## Weaknesses

- **Pre-1.0**: APIs have been frequently broken; not yet production-stable
- **Smaller ecosystem**: Fewer libraries and integrations than ZIO or Cats Effect
- **Scala 3 only**: Cannot be used with Scala 2.13 projects
- **Learning curve**: Algebraic effects and the `<` type require adjustment
- **Limited community**: Fewer resources, tutorials, and production experience
- **Performance not yet fully benchmarked**: Less evidence than ZIO/CE

## Key Design Decisions and Trade-offs

| Decision                           | Rationale                                                     | Trade-off                                            |
| ---------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------- |
| Open effect set                    | More precise effect tracking; user-defined effects            | More complex type signatures; unfamiliar pattern     |
| Contravariant S parameter          | Unifies map/flatMap; natural subtyping                        | Less intuitive variance; requires understanding      |
| Generalized effect rotation        | Each effect independently handleable                          | More complex internal implementation                 |
| Scala 3 only                       | Leverages intersection types, opaque types, context functions | Excludes Scala 2 users                               |
| Direct style aspiration            | More natural programming                                      | Still uses monadic `map`; not fully direct style yet |
| Algebraic effects (not fiber-only) | Theoretical generality; composability                         | Less optimized than purpose-built fiber runtimes     |

---

## 2024-2025 Developments

- **Road to 1.0**: Release candidate cycle announced; commitment to API stability
- **LLM integration**: "An Algebra of Thoughts: When Kyo Effects Meet LLMs" -- exploring effects for AI applications
- **Conference talks**: LambdaConf 2025 ("Redefining Stream Composition with Algebraic Effects"), Functional Scala 2024 ("The Actor Model Beyond Akka With Kyo")
- **Growing ecosystem**: kyo-http, kyo-streaming, kyo-actor modules

---

## Sources

- [Kyo GitHub repository](https://github.com/getkyo/kyo)
- [Kyo website](https://getkyo.io/)
- [Kyo on Scaladex](https://index.scala-lang.org/getkyo/kyo)
- [Writing Modular Applications Using The Kyo Library](https://www.scalamatters.io/post/writing-modular-applications-using-the-kyo-library) -- Scala Matters
- [What are Effect Systems and Why Do We Care?](https://idiomaticsoft.com/post/2024-01-02-effect-systems/) -- Idiomatic Soft
- [Kyo -- Functional Scala 2023 slides](https://speakerdeck.com/fwbrasil/kyo-functional-scala-2023) -- Flavio Brasil
- [Debasish Ghosh on Kyo's type encoding](https://x.com/debasishg/status/1881557372331856347)
