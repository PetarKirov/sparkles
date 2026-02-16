# ZIO (Scala)

A zero-dependency Scala library for asynchronous and concurrent programming, providing a batteries-included effect system with typed errors, built-in dependency injection, and a high-performance fiber runtime. ZIO has established itself as the "enterprise effect system" for Scala.

| Field         | Value                                                |
| ------------- | ---------------------------------------------------- |
| Language      | Scala 2.13 / Scala 3                                 |
| License       | Apache-2.0                                           |
| Repository    | [github.com/zio/zio](https://github.com/zio/zio)     |
| Documentation | [zio.dev](https://zio.dev)                           |
| Key Authors   | John De Goes (Ziverge)                               |
| Approach      | Fiber-based runtime with three-parameter effect type |

---

## Overview

### What It Solves

ZIO provides a comprehensive framework for building type-safe, concurrent, resource-safe applications in Scala. It replaces ad-hoc exception handling, manual thread management, and runtime dependency injection with a unified, type-safe effect system.

### Design Philosophy

ZIO is ruthlessly pragmatic: it eschews category-theory jargon and higher-kinded abstractions in favor of a concrete effect type (`ZIO[R, E, A]`) with clear, practical semantics. The approach is batteries-included -- ZIO ships with concurrent data structures, scheduling, STM, streaming, and dependency injection out of the box.

---

## Core Abstractions and Types

### ZIO[R, E, A]

The central type is parameterized by three types:

```scala
ZIO[-R, +E, +A]
```

A good intuition: `R => async Either[E, A]`

| Parameter           | Meaning                                   | Variance      | When `Any`/`Nothing`                    |
| ------------------- | ----------------------------------------- | ------------- | --------------------------------------- |
| **R** (Environment) | Contextual data required before execution | Contravariant | `Any` = no requirements                 |
| **E** (Error)       | Type of error the effect can fail with    | Covariant     | `Nothing` = cannot fail                 |
| **A** (Success)     | Type of value on success                  | Covariant     | `Nothing` = runs forever (unless fails) |

### Type Aliases

```scala
type UIO[+A]      = ZIO[Any, Nothing, A]    // no requirements, cannot fail
type URIO[-R, +A] = ZIO[R, Nothing, A]      // requires R, cannot fail
type Task[+A]     = ZIO[Any, Throwable, A]   // no requirements, may throw
type IO[+E, +A]   = ZIO[Any, E, A]           // no requirements, custom error
type RIO[-R, +A]  = ZIO[R, Throwable, A]     // requires R, may throw
```

### Immutable Effect Values

ZIO values are ordinary immutable values. They **model** effects without performing them. Effects are only executed when submitted to the ZIO runtime. This preserves referential transparency -- the same ZIO value always describes the same computation.

---

## How Effects Are Declared

### The Service Pattern

ZIO defines services as traits with effectful methods:

```scala
trait UserRepository:
  def getUser(id: UserId): IO[DBError, User]
  def saveUser(user: User): IO[DBError, Unit]
```

Services are accessed from the environment via `ZIO.service`:

```scala
def getUser(id: UserId): ZIO[UserRepository, DBError, User] =
  ZIO.serviceWithZIO[UserRepository](_.getUser(id))
```

### Effect Tracking via Type Parameters

The R parameter tracks dependencies, E tracks possible errors, and A tracks the success type. When composing effects that require different services, the resulting type requires the intersection of all services:

```scala
// Requires both UserRepository and Logger
def processUser(id: UserId): ZIO[UserRepository & Logger, AppError, Unit] = ???
```

---

## How Handlers/Interpreters Work

### ZLayer for Dependency Injection

`ZLayer[RIn, E, ROut]` describes how to create a service from its dependencies:

```scala
val userRepoLayer: ZLayer[Database, DBError, UserRepository] =
  ZLayer {
    for
      db <- ZIO.service[Database]
    yield UserRepositoryLive(db)
  }
```

### Layer Composition

| Operator | Name        | Description                                                    |
| -------- | ----------- | -------------------------------------------------------------- |
| `++`     | Horizontal  | Combines independent layers: `A ++ B` produces `A & B`         |
| `>>>`    | Vertical    | Chains dependent layers: output of first feeds input of second |
| `>+>`    | Passthrough | Like `>>>` but passes through all upstream outputs             |

### Automatic Wiring

```scala
myApp.provide(
  UserRepository.layer,
  Database.layer,
  Logger.layer,
  Config.layer
)
```

`ZIO.provide` (and `ZLayer.make`) automatically assembles the dependency graph from the available layers, verified at compile time. Cyclic dependencies are impossible by construction.

### Error Handling

```scala
// Catch and recover from errors
effect.catchAll(e => fallback)

// Fold over success/failure
effect.fold(errorHandler, successHandler)

// Convert between error channels
effect.mapError(transform)
effect.refineToOrDie[SpecificError]
```

---

## Performance Approach

### Fiber Runtime

ZIO uses lightweight fibers (green threads) for concurrency:

- Fibers are much cheaper than OS threads
- Millions of fibers can be active simultaneously
- Structured concurrency prevents resource leaks
- Fibers support interruption (cancellation) with resource safety

### Effect as Data Structure

Internally, `ZIO` values are reified as a tree of instructions that the runtime interprets. This is conceptually similar to a free monad but with a fixed, optimized instruction set. The runtime uses a trampoline-style evaluator to prevent stack overflow.

### Baked-In Effects

Unlike Haskell's approach of composing generic effect types, ZIO bakes common effects into its type:

- `ReaderT` is the `R` parameter
- `EitherT` is the `E` parameter
- `IO` is the runtime's fiber scheduler

This avoids the overhead of generic monad transformer stacking.

### Memory Footprint

ZIO fibers carry more context than Cats Effect fibers (roughly 3x larger memory footprint), which is the cost of the richer built-in features (typed errors, environment, etc.).

---

## Composability Model

### Monadic Composition

```scala
for
  config <- ZIO.service[Config]
  user   <- userRepo.getUser(config.adminId)
  _      <- logger.info(s"Found admin: ${user.name}")
yield user
```

### The Tri-Z Architecture

A recommended layering pattern:

1. **Inner Layer (ZPure)**: Pure, deterministic business logic -- no side effects, testable, replayable
2. **Middle Layer (ZSTM)**: Software Transactional Memory for concurrent state management
3. **Outer Layer (ZIO)**: Side effects, I/O, fiber scheduling

### Concurrent Primitives

Built-in concurrent data structures:

| Primitive   | Purpose                          |
| ----------- | -------------------------------- |
| `Ref`       | Atomic mutable reference         |
| `Promise`   | Single-value async communication |
| `Queue`     | Bounded/unbounded async queue    |
| `Semaphore` | Concurrency limiting             |
| `Hub`       | Pub/sub broadcasting             |
| `STM`       | Software transactional memory    |

---

## Strengths

- **Batteries-included**: STM, scheduling, streaming, testing, DI -- all built in
- **Typed errors**: The `E` parameter provides compile-time error tracking without Java's checked exceptions
- **ZLayer DI**: Compile-time verified dependency injection with automatic wiring
- **Enterprise adoption**: Largest Scala effect system community; extensive documentation and courses
- **Structured concurrency**: Fibers with interruption, scoping, and resource safety
- **Pragmatic design**: No category theory prerequisites; clear, concrete API
- **Strong testing support**: `ZIO Test` with testable `Clock`, `Random`, `Console` services

## Weaknesses

- **Not true algebraic effects**: Fixed to two effect channels (R and E); cannot define arbitrary new effect types
- **Heavier fibers**: ~3x memory overhead compared to Cats Effect fibers
- **No tagless final**: Concrete `ZIO` type; cannot abstract over effect implementation
- **Learning curve**: Three type parameters and the layer system take time to master
- **Ecosystem fragmentation**: Some libraries support only Cats Effect or only ZIO
- **Scala market decline**: Fewer companies adopting Scala for new projects

## Key Design Decisions and Trade-offs

| Decision                     | Rationale                                             | Trade-off                                                   |
| ---------------------------- | ----------------------------------------------------- | ----------------------------------------------------------- |
| Concrete ZIO type (not F[_]) | Simpler API; better error messages; no HKT complexity | No abstraction over effect implementation                   |
| Three type parameters        | Typed errors + dependency injection at type level     | Verbose type signatures; learning curve                     |
| Baked-in ReaderT + EitherT   | Avoids monad transformer overhead                     | Cannot add custom effect channels                           |
| ZLayer DI                    | Compile-time verified; automatic wiring               | Complex layer API; debugging wiring errors can be difficult |
| Batteries-included           | Lower dependency count; integrated experience         | Larger library; opinionated choices                         |
| Fiber-based concurrency      | Scalable; structured; resource-safe                   | Memory overhead; scheduler complexity                       |

---

## 2024-2025 Developments

- ZIO HTTP finalized as the community's backend solution
- Zionomicon (ZIO reference book) completed and distributed free
- Continued support for Scala 2.13 and Scala 3.x
- Exploration of Golem integration for cloud-native deployment
- ZIO ecosystem consolidation: some projects moved into core for better maintenance

---

## Sources

- [ZIO documentation](https://zio.dev)
- [ZIO GitHub repository](https://github.com/zio/zio)
- [ZIO in 2025](https://www.ziverge.com/post/zio-in-2025) -- Ziverge
- [ZIO core reference](https://zio.dev/reference/core/zio/)
- [Getting Started with DI in ZIO](https://zio.dev/reference/di/dependency-injection-in-zio/)
- [The Tri-Z Architecture](https://blog.pierre-ricadat.com/the-tri-z-architecture-a-pattern-for-layering-zio-applications-in-scala)
- [Structuring ZIO 2 Applications](https://softwaremill.com/structuring-zio-2-applications/) -- SoftwareMill
- [Cats Effect vs ZIO](https://softwaremill.com/cats-effect-vs-zio/) -- SoftwareMill
