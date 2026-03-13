# TurboLift (Scala)

A Scala 3 algebraic-effects library centered on typed effect sets, first-class handlers, and uniquely labelled effect instances. TurboLift explores advanced effect features (labelled effects, higher-order effects, applicative parallel composition, bidirectional effects) within idiomatic Scala syntax.

| Field         | Value                                                                    |
| ------------- | ------------------------------------------------------------------------ |
| Language      | Scala 3                                                                  |
| License       | MIT                                                                      |
| Repository    | [TurboLift GitHub repository]                                            |
| Documentation | [TurboLift microsite][TurboLift microsite]                               |
| Key Authors   | Marcin Zajączkowski                                                      |
| Encoding      | `Computation[A, U]` + typed handlers over intersection-typed effect sets |

---

## Overview

### What It Solves

TurboLift provides a strongly typed algebraic-effects model for Scala that is more open-ended than fixed-channel runtimes like [ZIO] and less typeclass-centric than [Cats Effect]. It targets modular effect composition while preserving direct and readable syntax.

### Design Philosophy

TurboLift aims to make advanced handler-based programming practical in Scala 3 using:

- Effect sets represented at the type level with intersection types.
- Explicit, reusable handlers as first-class values.
- Mandatory effect labelling to preserve modularity and avoid ambiguity.

The project is explicit about exploring features that are often absent or restricted in mainstream production effect libraries.

---

## Core Abstractions and Types

### Computation

The central type is:

```scala
Computation[+A, -U]
```

with infix alias:

```scala
A !! U
```

`A` is the produced value type, while `U` is the set of required effects.

### Effect Sets via Intersection Types

TurboLift models required effects as intersections:

- `Any` means no required effects.
- `X & Y` means both effects are required.

This allows inferred capability sets to remain visible in inferred types and compositional across modules.

### Effect, Signature, Interpreter, Handler

The official architecture describes five roles:

1. `Signature` (effect algebra/service interface).
2. `Effect` (operation-invocation surface).
3. `Interpreter` (semantic implementation).
4. `Handler` (scope-delimiting eliminator/transformer).
5. `Computation` (program description).

Handlers are polymorphic transformers over computations and can both eliminate requested effects and introduce dependencies.

---

## How Effects Are Declared

Effects are defined as signatures plus effect objects that perform operations:

```scala
trait FileSystemSignature extends Signature:
  def readFile(path: String): String !! ThisEffect
  def writeFile(path: String, contents: String): Unit !! ThisEffect

case object FileSystem extends Effect[FileSystemSignature] with FileSystemSignature:
  final override def readFile(path: String) = perform(_.readFile(path))
  final override def writeFile(path: String, contents: String) =
    perform(_.writeFile(path, contents))
```

TurboLift also supports predefined effects (for example, `Reader`, `State`, `Error`, `Choice`, etc.) and optional bindless syntax extensions.

---

## How Handlers/Interpreters Work

### Handler Application

Handlers delimit effect scopes and transform computation types:

```scala
val result =
  program
    .handleWith(State.handler(100))
    .handleWith(Reader.handler(3))
    .handleWith(Error.handler)
    .run
```

As effects are eliminated, the required effect set shrinks. Once no required effects remain (or only `IO`, depending on API path), execution can be finalized.

### Composition of Handlers

Handlers are composable values and can be transformed/combined with dedicated combinators (for example, independent composition operators documented in the handler API).

### Higher-Order and Scoped Operations

TurboLift explicitly supports higher-order/scoped operations and documents ordering-sensitive pitfalls from transformer ecosystems. Its examples emphasize consistent behavior under different handler orders for representative state/error scoped programs.

---

## Performance Approach

### Parallel/Applicative Composition

TurboLift includes parallel-friendly composition (`*!` / `zipPar`) where handlers permit it. If every active handler is parallelizable, branches can execute concurrently (implicit fiber fork/join); otherwise, composition falls back to sequential behavior.

### Handler-Dependent Parallelizability

The docs distinguish handlers that are parallelizable from those that are not (for example, linear local-state handlers vs aggregating/shared variants). This makes parallel behavior explicit in interpretation strategy rather than implicit in syntax alone.

### Benchmark Positioning

TurboLift’s official performance positioning points to [Effect Zoo] benchmarks and related benchmark suites rather than a single canonical chart in the core docs. The project narrative is "high performance with advanced feature support," with concrete numbers published in external benchmark repos.

---

## Composability Model

### Labelled Effects as Default

A defining trait is **always-labelled effects** (via singleton-typed effect instances). Multiple instances of the same effect family can safely coexist:

```scala
case object Foo extends State[Int]
case object Bar extends State[Int]
```

This directly addresses ambiguity and modularity challenges that appear in many effect systems.

### Bidirectional Effects

TurboLift supports operations that request both `ThisEffect` and additional effects, enabling explicit public dependencies in effect signatures. This separates interface-level dependencies from private interpreter dependencies and supports more structured modularity.

### Ecosystem Interop

The wider ecosystem includes companion projects (for example, [Spot] for Cats-Effect instances over TurboLift `IO`, [Beam], [Enterprise], [DaaE]). This indicates a growing but still niche integration story compared to [ZIO] and [Cats Effect].

---

## Strengths

- **Advanced feature set**: labelled, higher-order, bidirectional, and applicative/parallel patterns in one system.
- **First-class handler model**: explicit, composable effect elimination.
- **Strong type-level modularity**: intersection-typed effect sets stay visible in signatures.
- **Multiple same-family effects**: unique labels avoid common ambiguity pitfalls.
- **Modern Scala 3 ergonomics**: expressive syntax, optional bindless extension.

## Weaknesses

- **Smaller ecosystem/community**: far less industrial adoption than [ZIO] or [Cats Effect].
- **Evolving platform surface**: docs and APIs are ambitious and still maturing.
- **Conceptual complexity**: advanced handler semantics require deeper effect-system fluency.
- **Benchmark interpretation overhead**: performance understanding often requires consulting external benchmark repositories.
- **Scala 3 + Java baseline constraints**: requires modern toolchain (Java 11+).

## Key Design Decisions and Trade-offs

| Decision                                                     | Rationale                                                    | Trade-off                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------- |
| Intersection-typed effect sets (`U`)                         | Direct, compositional type-level effect tracking             | Verbose types for complex programs                |
| Always-labelled effect instances                             | True modularity; multiple same-family effects safely coexist | Slightly more declaration boilerplate             |
| First-class handlers                                         | Explicit semantics, reusable interpretation logic            | Higher conceptual load than single-runtime models |
| Built-in advanced features (HOE, applicative, bidirectional) | Rich expressiveness uncommon in mainstream stacks            | Larger semantic surface to learn and maintain     |
| Optional bindless DSL                                        | More direct-style ergonomics                                 | Extra module/dependency and tooling complexity    |

---

## Sources

- [TurboLift microsite]
- [TurboLift GitHub repository]
- [TurboLift overview]
- [TurboLift labelled effects]
- [TurboLift higher-order effects]
- [TurboLift bidirectional effects]
- [TurboLift applicative effects]
- [TurboLift on Scaladex]
- [Effect Zoo]

<!-- References -->

[ZIO]: scala-zio.md
[Cats Effect]: scala-cats-effect.md
[Kyo]: scala-kyo.md
[TurboLift microsite]: https://marcinzh.github.io/turbolift/
[TurboLift GitHub repository]: https://github.com/marcinzh/turbolift
[TurboLift overview]: https://marcinzh.github.io/turbolift/overview.html
[TurboLift labelled effects]: https://marcinzh.github.io/turbolift/advanced/labelled.html
[TurboLift higher-order effects]: https://marcinzh.github.io/turbolift/advanced/higher.html
[TurboLift bidirectional effects]: https://marcinzh.github.io/turbolift/advanced/bidir.html
[TurboLift applicative effects]: https://marcinzh.github.io/turbolift/advanced/applicative.html
[TurboLift on Scaladex]: https://index.scala-lang.org/marcinzh/turbolift
[Effect Zoo]: https://github.com/marcinzh/effect-zoo
[Spot]: https://github.com/marcinzh/spot
[Beam]: https://github.com/marcinzh/beam
[Enterprise]: https://github.com/marcinzh/enterprise
[DaaE]: https://github.com/marcinzh/daae
