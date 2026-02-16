# Cats Effect (Scala)

The pure asynchronous runtime for Scala, providing a concrete `IO` monad and a typeclass hierarchy that defines what it means to be a purely functional runtime system. Powers a thriving ecosystem including fs2, http4s, doobie, and more.

| Field         | Value                                                                        |
| ------------- | ---------------------------------------------------------------------------- |
| Language      | Scala 2.13 / Scala 3                                                         |
| License       | Apache-2.0                                                                   |
| Repository    | [github.com/typelevel/cats-effect](https://github.com/typelevel/cats-effect) |
| Documentation | [typelevel.org/cats-effect](https://typelevel.org/cats-effect/)              |
| Key Authors   | Daniel Spiewak, Typelevel community                                          |
| Approach      | Typeclass hierarchy + concrete IO monad + work-stealing fiber runtime        |

---

## Overview

### What It Solves

Cats Effect provides the tools to architect highly-asynchronous, highly-concurrent applications without sacrificing performance or composability. It addresses the fundamental challenge of mapping millions of logical fibers onto a small pool of OS threads efficiently and safely.

### Design Philosophy

Cats Effect follows the Typelevel philosophy: simple, orthogonal, primitive capabilities that compose to express all necessary computation. Unlike ZIO's batteries-included approach, Cats Effect is minimalist -- it provides the runtime and typeclass contracts, while the ecosystem provides the features. This enables maximum abstraction: code can be written against `F[_]` with typeclass constraints rather than a concrete IO type.

---

## Core Abstractions and Types

### IO[A]

The concrete effect type has a single type parameter:

```scala
IO[+A]
```

`IO[A]` represents a potentially side-effectful computation that produces a value of type `A`. Like ZIO, `IO` values are immutable descriptions of effects, not the effects themselves. They are executed by the runtime.

### Error Handling

Unlike ZIO's typed error channel, Cats Effect fixes the error type to `Throwable`:

```scala
// Errors are always Throwable
IO.raiseError(new RuntimeException("boom"))

// Recovery
io.handleErrorWith(e => IO.println(s"Error: $e"))
```

This simplifies the API and improves Java interoperability at the cost of type-level error tracking.

---

## The Typeclass Hierarchy

The typeclass hierarchy is the defining feature of Cats Effect. It defines contracts for progressively more powerful effect capabilities:

### Cats Effect 3 Hierarchy (Bottom to Top)

```
                    Monad
                      |
                   Unique
                      |
                  MonadCancel
                   /      \
              Spawn      GenConcurrent
               |              |
           Concurrent         |
               |              |
            Temporal     GenTemporal
               \            /
                \          /
                  Sync   Async
                    \   /
                     \ /
                    LiftIO
```

### Key Typeclasses

| Typeclass       | Capability             | Key Operations                        |
| --------------- | ---------------------- | ------------------------------------- |
| **MonadCancel** | Resource safety        | `bracket`, `uncancelable`, `onCancel` |
| **Spawn**       | Fiber management       | `start`, `racePair`                   |
| **Concurrent**  | Structured concurrency | `race`, `both`, `parTraverse`         |
| **Temporal**    | Wall-clock operations  | `sleep`, `timeout`, `now`             |
| **Sync**        | Synchronous FFI        | `delay`, `blocking`                   |
| **Async**       | Asynchronous FFI       | `async`, `evalOn`, `executionContext` |

### CE3 vs CE2: The Critical Redesign

In CE2, `Sync` and `Async` sat at the **top** of the hierarchy. This meant any time you needed even basic concurrency (`Concurrent`), you also brought `delay` into scope, losing all ability to reason about effects.

CE3 pushes `Sync` and `Async` to the **bottom**, so you can use `Concurrent` or `Temporal` without importing the ability to suspend arbitrary side effects. This dramatically improves the reasoning power of polymorphic effect code.

---

## How Effects Are Declared

### Tagless Final Style

Cats Effect uses the tagless final pattern -- services are defined as traits parameterized by an effect type `F[_]`:

```scala
trait UserRepository[F[_]]:
  def getUser(id: UserId): F[Option[User]]
  def saveUser(user: User): F[Unit]
```

Effect requirements are expressed via typeclass constraints:

```scala
def processUser[F[_]: Concurrent: Temporal](
  repo: UserRepository[F],
  logger: Logger[F]
): F[Unit] = ???
```

This allows the same code to run with `IO`, `SyncIO`, or any other effect type that satisfies the constraints.

### Resource Management

```scala
Resource.make(acquire)(release).use { resource =>
  // resource is available here
  // guaranteed cleanup via release
}
```

---

## How Handlers/Interpreters Work

### Effect Polymorphism

Because effects are expressed through typeclass constraints on `F[_]`, "handling" an effect means providing a concrete `F` that satisfies the constraints:

```scala
// Written against abstract F[_]
def program[F[_]: Async]: F[Unit] = ???

// "Handled" by choosing IO as the concrete type
program[IO].unsafeRunSync()
```

### No Equivalent to ZLayer

Cats Effect does not provide built-in dependency injection. Instead, the community uses:

- **Constructor injection**: Pass dependencies as parameters
- **Reader pattern**: Use `Kleisli[F, Env, A]` or similar
- **External libraries**: Smithy4s, Macwire, etc.

---

## Performance Approach

### Work-Stealing Fiber Runtime

Cats Effect 3 uses an extremely low-contention, lock-free work-stealing scheduler inspired by Tokio (Rust):

- **M:N scheduling**: Millions of fibers mapped to a small pool of OS threads
- **Scaling efficiency**: Gets _more_ efficient as processor count increases (unlike conventional `ExecutorService` which degrades quadratically)
- **Observed improvement**: ~55x more efficient than conventional approaches in typical scatter/gather microservice workloads

### Thread Pool Architecture

| Pool          | Purpose                       | Size                  |
| ------------- | ----------------------------- | --------------------- |
| **Compute**   | CPU-bound fiber evaluation    | ~number of processors |
| **Blocking**  | Blocking I/O operations       | Unbounded (cached)    |
| **Async I/O** | Event handling (epoll/kqueue) | 1-2 threads           |

### Cooperative + Preemptive Multitasking

- **Cooperative**: Fibers can explicitly yield via `IO.cede`
- **Preemptive (autoyield)**: Runtime forcibly yields fibers after a configurable number of actions, preventing starvation
- `IO.cede` has literally zero cost in the most common case due to scheduler integration

### Fiber Memory Footprint

Cats Effect fibers are roughly **3x smaller** than ZIO fibers in memory, since they carry less context (no typed error channel, no environment).

### io_uring Integration (v3.6.0)

The integrated runtime in CE 3.6.0 brought io_uring support, with observed **3.5x performance improvements** for HTTP microservices on http4s Ember.

---

## Composability Model

### Typeclass-Based Composition

Effects compose via typeclass constraints:

```scala
def program[F[_]: Concurrent: Temporal](
  http: HttpClient[F],
  db: Database[F]
): F[Result] =
  (http.fetch(url), db.query(sql)).parTupled
```

### Ecosystem Interoperability

The tagless final approach means the same library code works with any compliant runtime:

| Library | Domain               |
| ------- | -------------------- |
| fs2     | Streaming            |
| http4s  | HTTP client/server   |
| doobie  | JDBC database access |
| circe   | JSON serialization   |
| skunk   | PostgreSQL           |

### ZIO Interop

`zio-interop-cats` provides Cats Effect typeclass instances for ZIO, allowing ZIO programs to use Cats Effect libraries.

---

## Strengths

- **Lightweight fibers**: ~3x less memory than ZIO; highly scalable
- **Work-stealing scheduler**: Gets more efficient with more CPUs; inspired by Tokio
- **Tagless final**: Maximum abstraction; code works with any compliant effect type
- **Rich ecosystem**: fs2, http4s, doobie, etc. -- the largest FP Scala library ecosystem
- **Principled design**: Orthogonal typeclasses with laws; Discipline-based testing
- **CE3 hierarchy**: Better effect reasoning than CE2 by pushing Sync/Async down
- **io_uring support**: State-of-the-art I/O performance on Linux

## Weaknesses

- **No typed errors**: Fixed to `Throwable`; less type safety than ZIO's error channel
- **No built-in DI**: Must use external patterns or libraries for dependency injection
- **Tagless final overhead**: Higher-kinded abstractions can be confusing; error messages cryptic
- **Minimal built-in features**: No STM, scheduling, or streaming in core (requires fs2, etc.)
- **Learning curve**: Understanding the typeclass hierarchy requires FP background
- **No algebraic effects**: Fixed effect set defined by typeclass hierarchy

## Key Design Decisions and Trade-offs

| Decision                  | Rationale                             | Trade-off                               |
| ------------------------- | ------------------------------------- | --------------------------------------- |
| Tagless final (F[_])      | Maximum abstraction; library reuse    | HKT complexity; cryptic error messages  |
| Fixed Throwable errors    | Java interop; simpler API             | No typed error tracking                 |
| Minimal core              | Modularity; composability             | More dependencies needed for full apps  |
| Work-stealing scheduler   | Performance at scale                  | Complex runtime; harder to debug        |
| Separate Sync/Async (CE3) | Better effect reasoning               | Breaking change from CE2                |
| No DI system              | Keep core minimal; leave to ecosystem | Common pain point; no standard solution |

---

## Sources

- [Cats Effect documentation](https://typelevel.org/cats-effect/)
- [Cats Effect GitHub repository](https://github.com/typelevel/cats-effect)
- [Why Are Fibers Fast?](https://typelevel.org/blog/2021/02/21/fibers-fast-mkay.html) -- Typelevel Blog
- [Concurrency in Cats Effect 3](https://typelevel.org/blog/2020/10/30/concurrency-in-ce3.html) -- Typelevel Blog
- [Thread Model](https://typelevel.org/cats-effect/docs/thread-model) -- Cats Effect Docs
- [CE3 Proposal Issue #634](https://github.com/typelevel/cats-effect/issues/634)
- [CE2 Typeclass Overview](https://typelevel.org/cats-effect/docs/2.x/typeclasses/overview)
- [Cats Effect vs ZIO](https://softwaremill.com/cats-effect-vs-zio/) -- SoftwareMill
- [Comparative Benchmarks](https://gist.github.com/djspiewak/f4cfc08e0827088f17032e0e9099d292) -- Daniel Spiewak
- [Polymorphic Effects in Scala](https://timwspence.github.io/blog/posts/2020-11-22-polymorphic-effects-in-scala.html) -- Tim Spence
