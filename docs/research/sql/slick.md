# Slick (Scala)

Scala's _Functional Relational Mapping_ library: you write collection-style queries (`.filter`/`.map`/`.join`) over `TableQuery` values in a **lifted embedding** where every column is a `Rep[T]`, so `t.price < 10.0` builds a typed query AST rather than computing a `Boolean`, and Slick's query compiler renders that AST to dialect-specific SQL.

| Field              | Value                                                                                                                                                                                                          |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Scala (cross-built 2.12 / 2.13 / 3)                                                                                                                                                                            |
| License            | Two-clause BSD ("BSD-Style"), © 2011–2021 Lightbend, Inc. (formerly Typesafe) — [`LICENSE.txt`][license]                                                                                                       |
| Repository         | [slick/slick][repo]                                                                                                                                                                                            |
| Documentation      | [scala-slick.org][docs] · [stable manual][docsstable] · in-repo [`doc/paradox/`][docdir]                                                                                                                       |
| Category           | [Functional-relational mapper][concepts] — a [typed query builder][ladder] shading into a [functional data mapper][ladder]                                                                                     |
| Abstraction level  | Typed query builder / functional data mapper — above a driver, below a full ORM ([ladder][ladder])                                                                                                             |
| Query model        | [Typed relational algebra][qmodels] via a **lifted embedding** (columns are `Rep[T]`; queries are `Query[E, U, C]`)                                                                                            |
| Effect/async model | `DBIOAction[R, S, E]` — a **description** of DB work, run by an **effect-polymorphic** `db.run` to `F[R]` for any `cats.effect.Async` `F` (facades: `IO`/FS2, `Future`/Reactive Streams, ZIO `Task`/`ZStream`) |
| Backends           | PostgreSQL, MySQL, SQLServer, Oracle, DB2, Derby/JavaDB, H2, HSQLDB, SQLite — JDBC profiles ([`README.md`][readme])                                                                                            |
| First release      | ≈2012 (Slick 1.0 in 2013), successor to ScalaQuery (2008) — web-attested                                                                                                                                       |
| Latest version     | pinned checkout is the in-development **Slick 4** (Cats Effect 3 rewrite; `versionPolicyIntention := BumpMajor`); stable line is 3.6.x — web/soft                                                              |

> [!NOTE]
> Slick is this survey's data point for the **lifted-embedding** flavour of a [typed query
> builder][qmodels]: a query is a value in an embedded relational algebra whose columns carry their
> SQL type in the Scala type system, so an ill-typed comparison or a non-existent column is a
> _compile error_. It is the closest Scala analogue to `jOOQ`/`Diesel` on the construction axis, but
> — unlike them — it keeps _execution_ in a separate `DBIOAction` description type. The pinned
> checkout captures a pivotal moment: the historically `Future`-based runner has become
> effect-polymorphic over Cats Effect 3 / ZIO / Future, which is why it matters to an
> [effects-first][effects] survey. Compare with the quoted-DSL `Quill` and the `ConnectionIO`-based
> `doobie`.

---

## Overview

### What it solves

Slick sits in the gap between hand-written SQL strings and a classic ORM. Its self-description
([`README.md`][readme]):

> _"Slick is an advanced, comprehensive database access library for Scala with strongly-typed,
> highly composable APIs."_

The pitch is that a relational query should read like a Scala collection transformation while
staying under your explicit control ([`README.md`][readme]):

> _"It allows you to work with relational databases almost as if you were using Scala collections,
> while at the same time giving you full control over when the database is accessed and how much
> data is transferred. And by writing your queries in Scala you can benefit from compile-time
> safety and great compositionality, while retaining the ability to drop down to raw SQL when
> necessary for custom or advanced database features."_

The name encodes the design: **Scala Language-Integrated Connection Kit**. The manual's introduction
fixes the category and — crucially for this survey — the execution model
([`doc/paradox/introduction.md`][intro]):

> _"Slick (\"Scala Language-Integrated Connection Kit\") is Lightbend's Functional Relational
> Mapping (FRM) library for Scala that makes it easy to work with relational databases. It allows
> you to work with stored data almost as if you were using Scala collections while at the same time
> giving you full control over when database access happens and which data is transferred. You can
> also use SQL directly. Execution of database actions is done asynchronously, and Slick provides
> API facades for Cats Effect/FS2, Scala Future/Reactive Streams, and ZIO/ZStream."_

### Design philosophy

Slick is deliberately **not** an ORM, and the manual draws the boundary explicitly
([`doc/paradox/orm-to-slick.md`][ormtoslick]):

> _"A good term to describe Slick is functional-relational mapper. Slick allows working with
> relational data much like with immutable collections and focuses on flexible query composition and
> strongly controlled side-effects. ORMs usually expose mutable object-graphs, use side-effects like
> read- and write-caches and hard-code support for anticipated use-cases like inheritance or
> relationships via association tables. Slick focuses on getting the best out of accessing a
> relational data store. ORMs focus on persisting an object-graph."_

The FRM stance rejects the [identity map / unit-of-work][ormpatterns] machinery entirely
([`doc/paradox/orm-to-slick.md`][ormtoslick]):

> _"Slick in contrast does not expose an object-graph. It is inspired by SQL and the relational
> model and mostly just maps their concepts to the most closely corresponding, type-safe Scala
> features. Database queries are expressed using a restricted, immutable, purely-functional subset
> of Scala much like collections."_

Two consequences run through the whole library. First, **query construction and query execution are
separate** — a `Query` is a plan, not a result, and nothing touches the database until you turn the
plan into a `DBIOAction` and hand it to `db.run`. Second, the **[N+1 problem][nplusone] is avoided by
making joins explicit** rather than by prefetch hints: because you "navigate the object graph … by
composing queries instead" ([`doc/paradox/orm-to-slick.md`][ormtoslick]), "No database round trips
happen at all" until a single `.result`/`run` executes one query.

---

## Connection, pooling & resource lifetime

A Slick database is created from a `DatabaseConfig` (URL, `DataSource`, JNDI name, or HOCON config)
and, in the pinned checkout, is handed out as an **effect-scoped resource**. The Cats Effect facade
exposes acquire/release as a CE3 `Resource` ([`slick/cats/Database.scala`][catsdb]):

```scala
// slick/src/main/scala/slick/cats/Database.scala
def resource(config: DatabaseConfig): Resource[IO, Database] =
  Resource.make(make(config))(db => IO.blocking(db.close()).attempt.void)
```

The ZIO facade uses a `Scope` (`Database.scoped` → `ZIO[Scope, Throwable, Database]`) and the Future
facade a bracket-style `Database.use` ([`slick/zio/Database.scala`][ziodb],
[`slick/future/Database.scala`][futuredb]). This maps directly onto the survey's
[scoped acquire/release][pools] resource discipline: a leaked database is prevented structurally by
the effect system's resource combinator, not by a `finally`.

Connection pooling is delegated to **HikariCP** via the `slick-hikaricp` module, which "will use it
automatically when it is on the … classpath" ([`doc/paradox/database.md`][database]). The pinned
checkout re-implements Slick's admission and connection-slot control on Cats Effect primitives — a
`Semaphore`/`Ref`/`Deferred` arbiter ([`slick/basic/ConcurrencyControl.scala`][concurrency]) — and
surfaces the knobs through `ControlsConfig`:

```scala
// slick/basic pool controls, via ControlsConfig
DatabaseConfig.forProfileConfig(H2Profile, "mydb")
  .withControls(ControlsConfig(maxConnections = 10, queueSize = 500))
```

`maxConnections` bounds concurrent JDBC connections; `maxInflightActions` (default `2 *
maxConnections`) bounds concurrently-running `DBIOAction` chains; `connectionAcquireTimeout` bounds
the wait for a slot ([`doc/paradox/database.md`][database]). Because "Slick's execution model is
non-blocking, you do not need to add extra connections to 'absorb' thread blocking — size the pool
purely based on the database server's capacity" — a deliberate departure from the Slick 3.x model,
where the now-removed `AsyncExecutor` thread pool had to be sized alongside the connection pool
([`doc/paradox/migrating-to-slick4.md`][migrating]). JDBC row fetches are wrapped in `F.blocking`, so
an OS thread is occupied only during the actual fetch, not while awaiting non-database steps in a
composite action ([`doc/paradox/dbio.md`][dbio]).

---

## Query construction & injection safety

The query API is a **lifted embedding**, and the manual states the term precisely
([`doc/paradox/queries.md`][queries]):

> _"The API for building queries is a *lifted embedding*, which means that you are not working with
> standard Scala types but with types that are *lifted* into a Rep type constructor."_

The base of every lifted value is `Rep[T]` — a column, a literal, or a whole row — and every
operation is added by extension methods that inspect the `T` inside the `Rep`
([`slick/lifted/Rep.scala`][rep]):

```scala
// slick/src/main/scala/slick/lifted/Rep.scala
/** Common base trait for all lifted values, including columns. */
trait Rep[T] {
  /** Get the Node for this Rep. */
  def toNode: Node
}
```

The point of lifting is that a `Rep[Boolean]` expression is a **tree**, not a truth value. When you
write `c.price < 10.0`, the `<` operator does not compare two doubles — it constructs an AST `Node`
([`slick/lifted/ExtensionMethods.scala`][ext]):

```scala
// slick/src/main/scala/slick/lifted/ExtensionMethods.scala
def < [P2, R](e: Rep[P2])(implicit om: o#arg[B1, P2]#to[Boolean, R]) =
  om.column(Library.<, n, e.toNode)
def === [P2, R](e: Rep[P2])(implicit om: o#arg[B1, P2]#to[Boolean, R]) =
  om.column(Library.==, n, e.toNode)
```

`n` is `c.toNode` (the left operand's AST) and `e.toNode` the right; `Library.<` is the AST symbol
for the SQL `<`. The manual explains why this indirection is necessary
([`doc/paradox/queries.md`][queries]):

> _"This lifting is necessary because the lifted types allow us to generate a syntax tree that
> captures the query computations. Getting plain Scala functions and values would not give us enough
> information for translating those computations to SQL."_

Collections lift the same way: a `Query[E, U, C]` is itself a `Rep[C[U]]` carrying both the **mixed**
element type `E` (what you see, e.g. `(Rep[String], Rep[Double])`) and the **unpacked** type `U`
(what a run yields, e.g. `(String, Double)`) ([`slick/lifted/Query.scala`][query]). Its
`map`/`flatMap`/`filter` build query-AST nodes rather than iterating:

```scala
// slick/src/main/scala/slick/lifted/Query.scala
def flatMap[F, T, D[_]](f: E => Query[F, T, D]): Query[F, T, C] = {
  val generator = new AnonSymbol
  val aliased = shaped.encodeRef(Ref(generator)).value
  val fv = f(aliased)
  new WrappingQuery[F, T, C](Bind(generator, toNode, fv.toNode), fv.shaped)
}
```

Because `map`/`flatMap`/`filter`/`withFilter` are present with the right shapes, a Scala
`for`-comprehension over queries desugars into this AST-building machinery, giving the collection-like
surface syntax from the README:

```scala
// slick/README.md — the same query two ways
coffees.filter(_.price < 10.0).sortBy(_.name)
// or, as a for-comprehension:
for (c <- coffees if c.price < 10.0) yield c.name
// SQL: select NAME from COFFEES where PRICE < 10.0 order by NAME
```

**Injection safety is structural, twice over.** In the lifted API you never build SQL text at all —
values enter only as lifted literals or bind variables through the typed operators, so there is no
string to inject into; a stray Scala `String` in a predicate is a _type error_
([`doc/code/GettingStartedOverview.scala`][gettingstarted]: _"Using a string in the filter would
result in a compilation error"_). `filter` reinforces this by rejecting a plain `Boolean`: it
requires an implicit `CanBeQueryCondition`, so it "guards against the accidental use plain Booleans"
([`slick/lifted/Query.scala`][query]).

The **escape hatch** is Plain SQL, and it is safe by default. The `sql"…"` /`sqlu"…"` interpolators
turn every interpolated Scala value into a **bind parameter** ([`doc/paradox/sql.md`][sqldoc]):

> _"Any variable or expression injected into a query gets turned into a bind variable in the resulting
> query string. It is not inserted directly into a query string, so there is no danger of SQL
> injection attacks."_

The mechanism is visible in the interpolator: each `$value` appends a `?` and registers a
`SetParameter`, while the deliberate `#$expr` form (a trailing `#`) splices raw text — the one place
a user can reintroduce injection risk ([`slick/jdbc/StaticQuery.scala`][staticquery]):

```scala
// slick/src/main/scala/slick/jdbc/StaticQuery.scala — SQLActionBuilder.parse
if (literal) b.append(p.toString)   // "#$x": spliced verbatim (unsafe by choice)
else {
  b.append('?')                     // "$x": bound out-of-band (safe default)
  remaining += zipped._1.applied
}
```

`sql"…".as[R]` decodes the result set with an implicit `GetResult[R]`; `sqlu"…"` returns a
`DBIO[Int]` row count. Both are ordinary `DBIOAction`s, so Plain SQL composes with lifted queries in
the same action pipeline ([`slick/jdbc/StaticQuery.scala`][staticquery]).

### The query compiler

The lifted AST is not rendered directly — it flows through a multi-phase **query compiler** that
normalizes the tree, expands records/tables/sums, rewrites joins, and finally emits SQL. The standard
pipeline is a fixed vector of named phases ([`slick/compiler/QueryCompiler.scala`][querycompiler]):

```scala
// slick/src/main/scala/slick/compiler/QueryCompiler.scala (abridged)
val standardPhases = Vector(
  Phase.assignUniqueSymbols, Phase.unrollTailBinds,
  Phase.inferTypes, Phase.expandTables, Phase.forceOuterBinds, Phase.removeMappedTypes,
  Phase.expandSums, Phase.expandRecords, Phase.flattenProjections,
  Phase.rewriteJoins, Phase.verifySymbols, Phase.relabelUnions)
```

A `JdbcProfile` adds SQL-specific phases and a code-generation phase per statement kind
(`buildSelect`/`buildUpdate`/`buildDelete`, plus insert/upsert compilers) — this is the seam through
which one Scala query targets many dialects ([`slick/jdbc/JdbcProfile.scala`][jdbcprofile]).

---

## Schema, migrations & code generation

Slick is **code-first** for the schema description: you declare a `Table` subclass whose `*`
projection defines the row shape, and a `TableQuery` value gives you the query API over it
([`slick/relational/RelationalProfile.scala`][relprofile], [`README.md`][readme]):

```scala
// slick/README.md
final case class Coffee(name: String, price: Double)

class Coffees(tag: Tag) extends Table[Coffee](tag, "COFFEES") {
  def name  = column[String]("NAME")
  def price = column[Double]("PRICE")
  def * = (name, price).mapTo[Coffee]
}
val coffees = TableQuery[Coffees]
```

Each `column[C]("NAME", options*)` builds a `Rep[C]` whose AST node is a `Select` of a `FieldSymbol`
([`slick/relational/RelationalProfile.scala`][relprofile]); column options live under `O`
(`O.PrimaryKey`, `O.AutoInc`, `O.Unique`, `O.Length`, `O.Default`). Keys, foreign keys, and indexes
are ordinary methods on the `Table` (`primaryKey`, `foreignKey`, `index`) discovered by reflection
([`slick/lifted/AbstractTable.scala`][abstracttable]). This declaration is _also_ the DDL source:
`coffees.schema.create` (and `createIfNotExists`, `drop`) is a `DBIOAction` you run like any other.

Slick deliberately does **not** ship a migration runner. The manual is explicit
([`doc/paradox/migrations.md`][migrations]):

> _"Slick itself does not have out-of-the-box support for database migrations, but there are some
> third-party tools that work well with Slick."_

It points at Scala Forklift, `slick-migration-api`, and Flyway. This absence is a finding: unlike the
code-first ORMs (`EF Core`, `Prisma`) that emit migrations from the model, Slick owns the schema
_description_ but leaves schema _evolution_ to the ecosystem — see [migrations][schemamig] in the
concepts page.

Going the other direction, the `slick-codegen` module is **database-first**: it introspects a live
database and generates "`Table` classes, corresponding `TableQuery` values … as well as case classes
for holding complete rows" ([`doc/paradox/code-generation.md`][codegen]). Tables wider than Scala's
22-element tuple limit are generated with `HList`-based projections. So both schema stances are
supported: hand-write the `Table` classes, or generate them from an existing DB.

---

## Type mapping & result decoding

For lifted queries, the row shape is described by a **`Shape`**, and the result type is derived from
it. The `*` projection returns a `ProvenShape[T]` — a witness that a `Shape` exists to translate
between the `Rep`-based columns and the plain client-side type
([`slick/lifted/AbstractTable.scala`][abstracttable]). Mapping a tuple projection to a case class is
done with `<>` (a bidirectional factory/extractor pair) or the `mapTo` macro that derives it
([`slick/lifted/ShapedValue.scala`][shapedvalue]):

```scala
// slick/src/main/scala-2/slick/lifted/ShapedValue.scala
def <>[R : ClassTag](f: U => R, g: R => Option[U]) =
  new MappedProjection[R](/* … */)
def mapTo[R <: Product & Serializable](implicit rCT: ClassTag[R]): MappedProjection[R] =
  macro ShapedValue.mapToImpl[R, U]
```

Column-level type mapping is the profile's `ColumnType[T]` (for JDBC, `JdbcType[T]`); custom Scala
types map to a supported base type via `MappedColumnType`. **Nullability is in the type system**: an
optional column is `Rep[Option[T]]`, lifted with `?`, and Option-aware operators (`OptionMapper`)
propagate the `Option` into results — so a nullable column materializes as a Scala `Option`, as
concepts calls out for [nullability][typemap].

For Plain SQL, decoding is a `GetResult[R]` — literally a function from a positioned result row to `R`
— and binding is a `SetParameter[T]` ([`slick/jdbc/GetResult.fm`][getresult]):

```scala
// slick/src/main/scala/slick/jdbc/GetResult.fm
trait GetResult[+T] extends (PositionedResult => T) { self => /* … */ }
implicit object GetInt    extends GetResult[Int]    { def apply(rs: PositionedResult) = rs.nextInt() }
implicit object GetString extends GetResult[String] { def apply(rs: PositionedResult) = rs.nextString() }
```

These compose (tuples, options) and are resolved implicitly, so `sql"…".as[(Int, String)]` finds its
decoder at compile time — the same [codec/decoder][typemap] pattern as `doobie`'s `Read`/`Get`, minus
the automatic derivation for arbitrary case classes.

---

## Effect model, transactions & error handling

This is where the pinned checkout departs most sharply from the Slick most readers know. **Execution
is two-step.** Anything runnable — a query result (`myQuery.result`), a schema change
(`myTable.schema.create`), an insert (`myTable += item`) — is a `DBIOAction`, a _description_ of work,
not the work itself ([`slick/dbio/DBIOAction.scala`][dbioaction]):

> _"A Database I/O Action that can be executed on a database. The DBIOAction type allows a separation
> of execution logic and resource usage management logic from composition logic. DBIOActions can be
> composed with methods such as `andThen`, `andFinally` and `flatMap`."_

```scala
// slick/src/main/scala/slick/dbio/DBIOAction.scala
sealed trait DBIOAction[+R, +S <: NoStream, -E <: Effect] extends Dumpable {
  def map[R2](f: R => R2): DBIOAction[R2, NoStream, E] = flatMap(r => SuccessAction(f(r)))
  def flatMap[R2, S2 <: NoStream, E2 <: Effect](f: R => DBIOAction[R2, S2, E2]): DBIOAction[R2, S2, E with E2] = …
  def andThen[R2, S2 <: NoStream, E2 <: Effect](a: DBIOAction[R2, S2, E2]): DBIOAction[R2, S2, E with E2] = …
}
// type DBIO[+R] = DBIOAction[R, NoStream, Effect.All]
```

The `E` type parameter is a **phantom effect**: `Effect.Read`, `Effect.Write`, `Effect.Schema`,
`Effect.Transactional`, combined by intersection as actions compose. It tracks _capability_, not
error type ([`slick/dbio/Effect.scala`][effect]): _"The standard Slick back-ends do not restrict the
evaluation of actions based on effects but they can be used in user-level code (e.g. for ensuring
that all writes go to a master database but reads can also be performed by a slave)."_ Combinators
like `map`/`flatMap` — and therefore `for`-comprehensions — let you build a whole transactional
workflow as one value; notably, in this checkout they **no longer require an implicit
`ExecutionContext`** ([`doc/paradox/migrating-to-slick4.md`][migrating]).

**Running the description is effect-polymorphic.** The core database is parameterized by the effect
type ([`slick/Database.scala`][coredb]):

```scala
// slick/src/main/scala/slick/Database.scala
/** Effect-polymorphic database API. */
trait Database[F[_], S[_]] extends Closeable {
  /** Run a `DBIOAction` and return its result in `F[R]`. */
  def run[R](a: DBIOAction[R, NoStream, Nothing]): F[R]
  def stream[T](a: DBIOAction[?, Streaming[T], Nothing]): S[T]
}
```

The backend's interpreter runs against any `F[_]` with a `cats.effect.Async` instance
(`makeDatabase[F[_]: Async]`, [`slick/basic/BasicBackend.scala`][basicbackend]), and three ready-made
facades specialize it ([`doc/paradox/migrating-to-slick4.md`][migrating]):

| Facade                  | Module         | `db.run` returns             | `db.stream` returns                     |
| ----------------------- | -------------- | ---------------------------- | --------------------------------------- |
| `slick.cats.Database`   | `slick` (core) | `cats.effect.IO[R]`          | `fs2.Stream[IO, T]`                     |
| `slick.future.Database` | `slick-future` | `scala.concurrent.Future[R]` | Reactive Streams `DatabasePublisher[T]` |
| `slick.zio.Database`    | `slick-zio`    | `zio.Task[R]`                | `zio.stream.ZStream[Any, Throwable, T]` |

The Cats facade underscores that a `DBIOAction` is a lazy description, not an eager call
([`slick/cats/Database.scala`][catsdb]): _"The returned `IO` is lazy: the underlying `DBIOAction`
starts when the `IO` is run, not when it is created."_ The migration guide frames the whole change
([`doc/paradox/migrating-to-slick4.md`][migrating]):

> _"Slick 4 replaces the `Database.forXxx` factory methods and `scala.concurrent.Future`-returning
> execution layer with a new, three-facade API. The query DSL, SQL compiler pipeline, `DBIOAction`
> type and phantom effect system … all database profiles, and all SQL generation code are
> **completely unchanged**."_

So the survey's older framing — "Slick runs `DBIO` to a `Future`, so it is not effect-typed like
`doobie`/ZIO-`Quill`" — is now only half true, and precisely: the **composition type is still Slick's
own `DBIOAction`**, not an `IO`/`ZIO`/`ConnectionIO`, and it must be _interpreted_ to an effect
rather than being one. But the **interpreter is now effect-polymorphic**: the same action runs on
Cats Effect `IO`, ZIO `Task`, or `Future` with no code change, and the historical `Future`-only model
survives merely as the `slick-future` facade. Lifting a foreign effect _into_ an action is possible
too — `DBIO.from(F[R])`/`DBIO.liftF` embeds any `F[_]: Async` value in an action sequence
([`doc/paradox/dbio.md`][dbio]).

**Transactions.** `.transactionally` is a combinator that wraps an action so it commits or rolls back
atomically ([`slick/jdbc/JdbcActionComponent.scala`][jdbcaction]):

> _"Run this Action transactionally. … Depending on the outcome of running the Action it surrounds,
> the transaction is committed if the wrapped Action succeeds, or rolled back if the wrapped Action
> fails or the fiber is cancelled."_

```scala
// composing then wrapping in one transaction (doc/code/Connection.scala)
val a = (for {
  ns <- coffees.filter(_.name.startsWith("ESPRESSO")).map(_.name).result
  _  <- DBIO.seq(ns.map(n => coffees.filter(_.name === n).delete): _*)
} yield ()).transactionally
val f: IO[Unit] = db.run(a)
```

An overload takes an isolation level, `action.transactionally(TransactionIsolation.Serializable)`
([`doc/paradox/dbio.md`][dbio]). Two behaviours are worth pinning down. **Nesting has no savepoints**:
"An actual database transaction is only created and committed or rolled back for the outermost
`transactionally` action. Nested `transactionally` actions simply execute inside the existing
transaction without additional savepoints" ([`doc/paradox/dbio.md`][dbio]) — so unlike the
[savepoint-based nesting][savepoint] some effect systems offer, an inner block cannot roll back
independently. And the CE3 rewrite buys a guarantee the `Future` era could not
([`doc/paradox/dbio.md`][dbio]):

> _"in Slick 4 a transaction is rolled back not only on error but also on fiber cancellation. This
> guarantee was not possible with `Future`-based execution."_

A forced rollback is just `DBIO.failed(...)` inside the transactional action; `withPinnedSession`
pins one session without a transaction ([`slick/dbio/DBIOAction.scala`][dbioaction]).

**Error handling is `Throwable`-based, not a typed channel.** A `DBIOAction` has no error-type
parameter; failures propagate as exceptions in `F`'s error channel and are handled with combinators —
`andFinally` (cleanup regardless of outcome), `cleanUp` (transform the failure), `asTry`
(`DBIOAction[Try[R]]`), and `failed` (recover the `Throwable`) ([`doc/paradox/dbio.md`][dbio]). This
is the key contrast with the [typed-error][effects] effect mappers: where `doobie` keeps errors in
its effect's error type and `Quill`'s ZIO contexts narrow to a `SQLException` channel, Slick's `E`
tracks read/write/schema/transactional _capability_ and says nothing about _which errors_ a query can
raise. `cleanUp`/`andFinally` do run on fiber cancellation (`cleanUp` receives
`Some(CancellationException)`), while `asTry`/`failed` do not intercept it
([`doc/paradox/dbio.md`][dbio]).

---

## Ecosystem & maturity

Slick is a long-standing, widely-deployed Scala library, published under the group id
`com.typesafe.slick`, licensed under a two-clause BSD ("BSD-Style") license © Lightbend
([`LICENSE.txt`][license], [`README.md`][readme]). It descends from Stefan Zeiger's ScalaQuery
(2008), was rebranded and rewritten as Slick under Typesafe/Lightbend (≈2012, 1.0 in 2013), and is
today **community-maintained** — the README notes "Slick is community-maintained: pull requests are
very welcome" and that Lightbend staff "may be able to assist with administrative issues"
([`README.md`][readme]).

The nine JDBC-backed databases are covered "by a large suite of automated tests": PostgreSQL, MySQL,
SQLServer, Oracle, DB2, Derby/JavaDB, H2, HSQLDB, and SQLite ([`README.md`][readme]). The extended
ecosystem includes `slick-codegen` (introspection codegen), `slick-hikaricp` (pooling),
`slick-testkit` (a profile conformance kit), and third-party migration tools. The pinned checkout is
the **in-development Slick 4** — a full re-platforming of the runner onto Cats Effect 3
(`cats-effect 3.7`), FS2 (`fs2-core 3.13`), and ZIO (`zio 2.1`) per
[`project/Dependencies.scala`][deps] — while keeping the query DSL, compiler, profiles, and
`DBIOAction` model source-compatible with 3.x. The current _stable_ line remains 3.6.x
(web-attested).

---

## Strengths

- **Collection-like queries, checked at compile time.** `.filter`/`.map`/`.join` and
  `for`-comprehensions over `TableQuery`s read like Scala collections; a mistyped comparison or a
  missing column is a compile error, and values enter only as typed literals/binds — injection is
  structurally impossible in the lifted API.
- **One source, many dialects.** An extensible, phased query compiler renders the same Scala query to
  PostgreSQL/MySQL/H2/… SQL, papering over dialect quirks.
- **Explicit execution.** `Query` (a plan) and `DBIOAction` (a runnable description) are separate
  values; round trips are visible and easy to reason about, and there is no hidden lazy-loading or
  flush.
- **Composability at three levels** ([`README.md`][readme]): actions, queries, and row expressions
  each compose with `for`-comprehensions/combinators.
- **Effect-polymorphic in Slick 4.** The same `DBIOAction` runs on Cats Effect `IO`, ZIO `Task`, or
  `Future`; transactions are now rolled back on fiber cancellation, and pool/resource lifetime is a
  CE3 `Resource` / ZIO `Scope`.
- **Safe Plain SQL escape hatch.** `sql"…"`/`sqlu"…"` bind interpolated values as parameters by
  default and compose as ordinary actions; `GetResult`/`SetParameter` give typed decoding.
- **Code generation** from an existing schema (`slick-codegen`), including wide tables via `HList`.

## Weaknesses

- **Complex, implicit-heavy signatures.** The manual itself concedes that, because a `Query` carries
  both lifted and plain component types, "the signatures for these methods are very complex"
  ([`doc/paradox/queries.md`][queries]); `Shape`/`CanBeQueryCondition`/`OptionMapper` implicits make
  compile errors notoriously hard to read.
- **Operator gotchas.** You must use `===`/`=!=` (not `==`/`!=`) and `++` (not `+`) for `Rep`
  values, because the universal `Any` operators cannot be overridden ([`doc/paradox/queries.md`][queries]).
- **No typed error channel.** Failures are `Throwable` in `F`'s error channel; there is no
  enumerated/typed error set as in `doobie` or the Effect TS `SqlError` union.
- **No built-in migrations.** Schema _evolution_ is left entirely to third-party tools
  ([`doc/paradox/migrations.md`][migrations]).
- **Nested transactions are shallow.** Inner `transactionally` scopes add no savepoints; only the
  outermost is a real transaction, so partial rollback is not available ([`doc/paradox/dbio.md`][dbio]).
- **SQL can surprise you.** Monadic joins are compiled down to applicative joins
  ([`doc/paradox/queries.md`][queries]), and complex lifted queries occasionally generate
  non-obvious or suboptimal SQL — the price of a general compiler.
- **In flux.** The pinned Slick 4 is a pre-release rewrite; the construction API (`Database.forXxx` →
  `DatabaseConfig` + facade) has churned versus the deployed 3.x line.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                     | Trade-off                                                                                         |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Lifted embedding** — columns are `Rep[T]`, ops build an AST | Collection-like, compile-time-typed queries; injection-proof; one AST retargets many dialects | Implicit-heavy, hard-to-read signatures and errors; `===`/`++` gotchas; occasional surprising SQL |
| **`DBIOAction` as a separate description type**               | Query construction vs execution split; compose DB work as data; explicit round trips          | Extra type to learn; `DBIO` is _not_ your effect monad — it must be interpreted to an `F`         |
| **Effect-polymorphic runner (`F[_]: Async`) + three facades** | One library across Cats Effect / ZIO / Future; no effect-system lock-in                       | In-development (Slick 4); construction API churn vs the stable 3.x `Future` line                  |
| **Phantom `Effect` type (Read/Write/Schema/Transactional)**   | Tracks capability for user policies (e.g. route writes to a primary)                          | Not enforced by standard backends; not an error channel                                           |
| **Errors as `Throwable` in `F`'s channel**                    | Simple; interops with the host effect's error handling                                        | No typed/enumerated error set (unlike `doobie`/Effect TS)                                         |
| **No built-in migration runner**                              | Small, unopinionated surface; schema _description_ ≠ schema _evolution_                       | Depends on third parties (Flyway, `slick-migration-api`, Scala Forklift)                          |
| **`transactionally` = outermost-only, no savepoints**         | Deterministic, simple transaction boundary                                                    | No independent nested rollback; no partial rollback within a transaction                          |
| **Code-first `Table` + database-first `slick-codegen`**       | Hand-write schemas _or_ generate them from a live DB                                          | The `Table` DSL is boilerplate; generated code and hand-written code can drift                    |

---

## Sources

- [slick/slick — GitHub repository][repo] · [scala-slick.org documentation][docs] · [in-repo `doc/paradox/`][docdir]
- [`README.md` — positioning, collection-like queries, database support, community maintenance][readme]
- [`doc/paradox/introduction.md` — FRM definition, three facades, explicit execution][intro]
- [`doc/paradox/orm-to-slick.md` — functional-relational vs ORM; no object-graph; joins vs prefetch][ormtoslick]
- [`doc/paradox/queries.md` — the lifted embedding, `Rep`, `Query`, why lifting is needed][queries]
- [`doc/paradox/dbio.md` — `DBIOAction` combinators, `transactionally`, cancellation, nesting][dbio]
- [`doc/paradox/sql.md` — Plain SQL interpolation and bind-variable injection safety][sqldoc]
- [`doc/paradox/migrating-to-slick4.md` — three-facade rewrite; what changed vs 3.x][migrating]
- [`slick/dbio/DBIOAction.scala` — the action type + combinators][dbioaction] · [`slick/dbio/Effect.scala` — phantom effects][effect]
- [`slick/Database.scala` — effect-polymorphic core][coredb] · [`slick/cats/Database.scala`][catsdb] · [`slick/future/Database.scala`][futuredb] · [`slick/zio/Database.scala`][ziodb]
- [`slick/basic/BasicBackend.scala` — `makeDatabase[F: Async]`, interpreter state][basicbackend] · [`slick/basic/ConcurrencyControl.scala`][concurrency]
- [`slick/lifted/Rep.scala`][rep] · [`slick/lifted/Query.scala`][query] · [`slick/lifted/ExtensionMethods.scala`][ext] · [`slick/lifted/AbstractTable.scala`][abstracttable] · [`slick/lifted/ShapedValue.scala`][shapedvalue]
- [`slick/relational/RelationalProfile.scala` — `Table`, `column`][relprofile] · [`slick/jdbc/JdbcProfile.scala`][jdbcprofile] · [`slick/jdbc/JdbcActionComponent.scala` — `transactionally`][jdbcaction]
- [`slick/jdbc/StaticQuery.scala` — `sql`/`sqlu` interpolators][staticquery] · [`slick/jdbc/GetResult.fm`][getresult]
- [`slick/compiler/QueryCompiler.scala` — the phase pipeline][querycompiler] · [`project/Dependencies.scala` — CE3/FS2/ZIO versions][deps]
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [effects, transactions & errors][effects] · [ORM patterns][ormpatterns] · [N+1][nplusone]

<!-- References -->

[repo]: https://github.com/slick/slick
[docs]: https://scala-slick.org
[docsstable]: https://scala-slick.org/doc/stable/
[docdir]: https://github.com/slick/slick/tree/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox
[readme]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/README.md
[license]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/LICENSE.txt
[intro]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/introduction.md
[ormtoslick]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/orm-to-slick.md
[queries]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/queries.md
[dbio]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/dbio.md
[sqldoc]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/sql.md
[migrating]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/migrating-to-slick4.md
[migrations]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/migrations.md
[codegen]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/code-generation.md
[database]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/paradox/database.md
[gettingstarted]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/doc/code/GettingStartedOverview.scala
[dbioaction]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/dbio/DBIOAction.scala
[effect]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/dbio/Effect.scala
[coredb]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/Database.scala
[catsdb]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/cats/Database.scala
[futuredb]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick-future/src/main/scala/slick/future/Database.scala
[ziodb]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick-zio/src/main/scala/slick/zio/Database.scala
[basicbackend]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/basic/BasicBackend.scala
[concurrency]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/basic/ConcurrencyControl.scala
[rep]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/lifted/Rep.scala
[query]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/lifted/Query.scala
[ext]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/lifted/ExtensionMethods.scala
[abstracttable]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/lifted/AbstractTable.scala
[shapedvalue]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala-2/slick/lifted/ShapedValue.scala
[relprofile]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/relational/RelationalProfile.scala
[jdbcprofile]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/jdbc/JdbcProfile.scala
[jdbcaction]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/jdbc/JdbcActionComponent.scala
[staticquery]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/jdbc/StaticQuery.scala
[getresult]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/jdbc/GetResult.fm
[querycompiler]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/slick/src/main/scala/slick/compiler/QueryCompiler.scala
[deps]: https://github.com/slick/slick/blob/f16973aca78129b7f05783ef00f9f2ffec0afa6c/project/Dependencies.scala
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[schemamig]: ./concepts.md#schema-migrations-code-generation
[ormpatterns]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[savepoint]: ./concepts.md#effects-transactions-and-error-handling
