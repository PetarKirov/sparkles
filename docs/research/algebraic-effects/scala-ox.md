# Ox (Scala)

Safe direct-style streaming, concurrency, and resiliency for Scala on the JVM. Ox leverages Java 21 virtual threads to provide a direct-style alternative to monadic effect systems.

| Field         | Value                                                                     |
| ------------- | ------------------------------------------------------------------------- |
| Language      | Scala 3 (JVM only)                                                        |
| License       | Apache-2.0                                                                |
| Repository    | [github.com/softwaremill/ox](https://github.com/softwaremill/ox)          |
| Documentation | [ox.softwaremill.com](https://ox.softwaremill.com/)                       |
| Key Authors   | Adam Warski, SoftwareMill                                                 |
| Approach      | Direct style on virtual threads; IO capability; boundary/break for errors |

---

## Overview

### What It Solves

Ox provides safe concurrency and error handling in direct style -- no monads, no `flatMap`, no effect wrappers. Computations return values directly, and effects are tracked through Scala 3's capability system. Ox targets the practical middle ground between unsafe imperative I/O and the complexity of monadic effect systems.

### Design Philosophy

Direct style means that results of effectful computations are available directly, without a wrapper type such as `Future`, `IO`, or `Task`. Ox uses Java 21 virtual threads for concurrency, Go-like channels for inter-thread communication, and Scala 3 context functions for effect tracking.

---

## Core Abstractions and Types

### No Wrapper Type

Unlike ZIO (`ZIO[R,E,A]`) or Cats Effect (`IO[A]`), Ox does not have an effect wrapper. Functions return their result type directly:

```scala
// Ox style -- direct
def fetchUser(id: UserId)(using Ox): User = ???

// vs. ZIO style -- wrapped
def fetchUser(id: UserId): ZIO[Any, Error, User] = ???
```

### The IO Capability

```scala
import ox.IO

def readFile(path: String)(using IO): String =
  scala.io.Source.fromFile(path).mkString
```

`IO` is a capability (context parameter) that signals a method performs I/O. The goal is for method signatures to be truthful about their side effects. `IO` is passed implicitly via Scala's `using` clauses.

### Structured Concurrency

```scala
import ox.*

supervised {
  val f1 = fork { computeA() }
  val f2 = fork { computeB() }
  f1.join() + f2.join()
}
```

Forked computations are bound to a `supervised` scope. If any fork fails, all siblings are interrupted. Resources are always cleaned up.

### Channels (Go-style)

```scala
val ch = Channel.buffered[Int](10)

fork { ch.send(42) }
val value = ch.receive()  // blocks on virtual thread
```

### Error Handling via Boundary/Break

```scala
import ox.either
import ox.either.*

val result: Either[String, Int] = either:
  val x = Right(1).ok()      // .ok() breaks with Left on failure
  val y = Right(2).ok()
  x + y
```

---

## How Effects Are Tracked

### IO Capability

The `IO` capability indicates I/O effects:

```scala
def pure(x: Int): Int = x * 2          // no IO needed
def impure(using IO): String = readLine() // requires IO
```

### Ox Scope Capability

The `Ox` capability indicates structured concurrency scope:

```scala
def concurrent(using Ox): Int =
  val f = fork { expensive() }
  f.join()
```

### Typed Errors

Using `boundary`/`break` patterns for typed error handling without wrapper types.

---

## Performance Approach

### Virtual Threads (Project Loom)

Ox runs on Java 21+ virtual threads:

- Virtual threads are lightweight (~1KB initial stack)
- Millions can run concurrently
- Blocking operations do not waste OS threads
- JVM handles M:N scheduling natively

### No Abstraction Overhead

Because there is no effect wrapper, there is no monadic bind overhead, no free monad tree construction, and no effect dispatch mechanism. Function calls are plain JVM method calls.

### Platform Limitation

Ox is JVM-only by design. It cannot run on Scala.js or Scala Native because it depends on JVM virtual threads.

---

## Composability Model

### Direct Composition

Effects compose through normal function calls:

```scala
def processUser(id: UserId)(using IO, Ox): Result =
  val user = fetchUser(id)       // IO effect
  val enriched = fork { enrich(user) }  // concurrency effect
  save(enriched.join())           // IO effect
```

### No Effect Handlers

Unlike algebraic effect systems, Ox does not have "handlers" that interpret effects differently. The `IO` capability is not interceptable -- it simply marks that I/O happens. This is simpler but less flexible.

### Resiliency Utilities

Ox provides utilities for retry, rate limiting, timeout, and circuit breaking that work in direct style.

---

## Strengths

- **True direct style**: No wrapper types; code reads naturally
- **Virtual thread performance**: Millions of concurrent operations
- **Structured concurrency**: Safe resource management; no leaked fibers
- **Go-like channels**: Familiar concurrent communication model
- **Minimal learning curve**: If you know Scala, you can use Ox immediately
- **Typed errors without monads**: boundary/break pattern

## Weaknesses

- **JVM only**: Cannot target Scala.js or Scala Native
- **No effect handlers**: Cannot reinterpret effects; IO is not mockable via the type system
- **Limited effect tracking**: Only IO and Ox capabilities; no user-defined effects
- **Java 21+ required**: Needs modern JVM
- **Not algebraic effects**: No continuation capture; no nondeterminism; no effect rotation
- **Smaller ecosystem**: Fewer integrations than ZIO or Cats Effect

## Key Design Decisions and Trade-offs

| Decision                  | Rationale                                     | Trade-off                                                     |
| ------------------------- | --------------------------------------------- | ------------------------------------------------------------- |
| Direct style (no wrapper) | Simplicity; readability; no monadic overhead  | Cannot abstract over effect implementation                    |
| Virtual threads           | JVM-native concurrency; excellent performance | JVM-only; Java 21+ required                                   |
| IO as capability          | Truthful method signatures                    | Cannot intercept or mock IO at type level                     |
| Go-like channels          | Familiar model; proven design                 | Different paradigm from streaming libraries (fs2, ZIO Stream) |
| No effect handlers        | Simplicity; lower learning curve              | Less flexibility; no testable effect interpretation           |

---

## Sources

- [Ox GitHub repository](https://github.com/softwaremill/ox)
- [Ox documentation](https://ox.softwaremill.com/)
- [IO Effect Tracking Using Ox](https://softwaremill.com/io-effect-tracking-using-ox/) -- SoftwareMill
- [Direct style -- Ox documentation](https://ox.softwaremill.com/latest/basics/direct-style.html)
- [How Functional is Direct-Style?](https://2025.workshop.scala-lang.org/details/scala-2025/1/How-Functional-is-Direct-Style-) -- Scala Workshop 2025
